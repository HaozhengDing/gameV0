#ifndef SIMCORE_BENCH_PNG_WRITER_H
#define SIMCORE_BENCH_PNG_WRITER_H

#include <cstdint>
#include <string>

namespace bench {

// 用 zlib 写一个 8bit RGBA PNG（无第三方 PNG 库）。
// rgba 行优先，w*h*4 字节。成功返回 true。
bool write_png_rgba8(const std::string& path, const uint8_t* rgba, int width, int height);

}  // namespace bench

#endif  // SIMCORE_BENCH_PNG_WRITER_H
