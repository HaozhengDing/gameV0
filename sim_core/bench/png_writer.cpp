#include "png_writer.h"

#ifdef SIM_BENCH_NO_ZLIB
namespace bench {
bool write_png_rgba8(const std::string& /*path*/, const uint8_t* /*rgba*/, int /*width*/,
                     int /*height*/) {
    return false;
}
}  // namespace bench
#else
#include <zlib.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

namespace bench {
namespace {

void put_u32_be(std::vector<uint8_t>* out, uint32_t v) {
    out->push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
    out->push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    out->push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out->push_back(static_cast<uint8_t>(v & 0xFF));
}

bool write_chunk(std::ofstream& f, const char type[4], const uint8_t* data, size_t size) {
    std::vector<uint8_t> head;
    put_u32_be(&head, static_cast<uint32_t>(size));
    f.write(reinterpret_cast<const char*>(head.data()), static_cast<std::streamsize>(head.size()));
    f.write(type, 4);
    if (size > 0) {
        f.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(size));
    }
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, reinterpret_cast<const Bytef*>(type), 4);
    if (size > 0) crc = crc32(crc, data, static_cast<uInt>(size));
    std::vector<uint8_t> crcbuf;
    put_u32_be(&crcbuf, static_cast<uint32_t>(crc));
    f.write(reinterpret_cast<const char*>(crcbuf.data()), 4);
    return f.good();
}

}  // namespace

bool write_png_rgba8(const std::string& path, const uint8_t* rgba, int width, int height) {
    if (rgba == nullptr || width <= 0 || height <= 0) return false;
    // 原始扫描线：每行 1 字节 filter(0) + width*4 字节 RGBA
    const size_t row_bytes = static_cast<size_t>(width) * 4u + 1u;
    std::vector<uint8_t> raw(row_bytes * static_cast<size_t>(height));
    for (int y = 0; y < height; ++y) {
        uint8_t* row = raw.data() + static_cast<size_t>(y) * row_bytes;
        row[0] = 0;  // filter type: None
        std::memcpy(row + 1, rgba + static_cast<size_t>(y) * static_cast<size_t>(width) * 4u,
                    static_cast<size_t>(width) * 4u);
    }
    uLongf comp_len = compressBound(static_cast<uLong>(raw.size()));
    std::vector<uint8_t> comp(comp_len);
    const int zr = compress2(comp.data(), &comp_len, raw.data(), static_cast<uLong>(raw.size()), 6);
    if (zr != Z_OK) return false;
    comp.resize(comp_len);

    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    f.write(reinterpret_cast<const char*>(sig), 8);

    // IHDR
    std::vector<uint8_t> ihdr;
    put_u32_be(&ihdr, static_cast<uint32_t>(width));
    put_u32_be(&ihdr, static_cast<uint32_t>(height));
    ihdr.push_back(8);  // bit depth
    ihdr.push_back(6);  // color type RGBA
    ihdr.push_back(0);  // compression
    ihdr.push_back(0);  // filter
    ihdr.push_back(0);  // interlace
    if (!write_chunk(f, "IHDR", ihdr.data(), ihdr.size())) return false;
    if (!write_chunk(f, "IDAT", comp.data(), comp.size())) return false;
    if (!write_chunk(f, "IEND", nullptr, 0)) return false;
    f.flush();
    return f.good();
}

}  // namespace bench
#endif
