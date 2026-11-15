// sim_core ctest：确定性 / 挖掘 / 守恒与边界 / C API 契约 / materials.json 参数。
// 用法：sim_core_tests <test_name|all> [--materials <data/materials.json>]
// 每个用例失败返回 false，main 汇总后以非 0 退出。

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sim/c_sim.h"

namespace {

uint64_t mix64(uint64_t z) {
    z += 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

sim_world* make_world(uint32_t w, uint32_t h, uint64_t seed, const char* materials_path) {
    sim_config cfg{};
    cfg.width = w;
    cfg.height = h;
    cfg.seed = seed;
    cfg.chunk_size = 64;
    cfg.fixed_dt = 1.0f / 60.0f;
    cfg.materials_json_path = materials_path;
    return sim_world_create(&cfg);
}

// 用坐标 hash 生成初始材质（不依赖迭代顺序，两个 world 可复现同一图案）。
uint16_t pattern_material(int32_t x, int32_t y, uint64_t seed) {
    const uint64_t h = mix64(seed ^ (static_cast<uint64_t>(static_cast<uint32_t>(x)) *
                                     0xD6E8FEB86659FD93ULL) ^
                             (static_cast<uint64_t>(static_cast<uint32_t>(y)) << 32));
    const uint32_t pct = static_cast<uint32_t>(h % 100u);
    if (pct < 20) return SIM_MAT_SAND;
    if (pct < 45) return SIM_MAT_WATER;
    if (pct < 55) return SIM_MAT_OIL;
    if (pct < 62) return SIM_MAT_QUICKSILVER;
    return SIM_MAT_EMPTY;
}

void fill_pattern(sim_world* w, uint32_t w_, uint32_t h_, uint64_t seed) {
    for (uint32_t y = 0; y < h_; ++y) {
        for (uint32_t x = 0; x < w_; ++x) {
            const uint16_t m = pattern_material(static_cast<int32_t>(x), static_cast<int32_t>(y), seed);
            if (m != SIM_MAT_EMPTY) {
                sim_world_set_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(y), m);
            }
        }
    }
}

uint64_t count_material(const sim_world* w, uint32_t w_, uint32_t h_, uint16_t mat) {
    uint64_t n = 0;
    for (uint32_t y = 0; y < h_; ++y) {
        for (uint32_t x = 0; x < w_; ++x) {
            if (sim_world_get_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(y)).material == mat) {
                ++n;
            }
        }
    }
    return n;
}

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            std::fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            return false;                                                 \
        }                                                                 \
    } while (0)

#define CHECK_NEAR(a, b, eps) CHECK(std::fabs(static_cast<double>(a) - static_cast<double>(b)) <= (eps))

// ---------------------------------------------------------------------------
// 1) 确定性：同 seed / 同操作序列 → 两次运行 hash 完全相同
// ---------------------------------------------------------------------------
bool test_determinism(const std::string& /*materials*/) {
    const uint32_t W = 320, H = 240;
    sim_world* a = make_world(W, H, 0x5EED1234ULL, nullptr);
    sim_world* b = make_world(W, H, 0x5EED1234ULL, nullptr);
    CHECK(a != nullptr);
    CHECK(b != nullptr);
    fill_pattern(a, W, H, 0x5EED1234ULL);
    fill_pattern(b, W, H, 0x5EED1234ULL);
    CHECK(sim_world_hash(a) == sim_world_hash(b));
    for (int i = 0; i < 400; ++i) {
        sim_world_step(a);
        sim_world_step(b);
        if (i % 37 == 0 || i == 399) {
            CHECK(sim_world_tick(a) == sim_world_tick(b));
            CHECK(sim_world_hash(a) == sim_world_hash(b));
        }
    }
    // 不同 seed 的同一图案应当发散（防止 hash 退化）
    sim_world* c = make_world(W, H, 0x12345678ULL, nullptr);
    CHECK(c != nullptr);
    fill_pattern(c, W, H, 0x5EED1234ULL);
    for (int i = 0; i < 50; ++i) sim_world_step(c);
    CHECK(sim_world_hash(c) != sim_world_hash(a));
    sim_world_destroy(a);
    sim_world_destroy(b);
    sim_world_destroy(c);
    return true;
}

// ---------------------------------------------------------------------------
// 2) 挖掘：圆形挖掉实心格、产生空腔/碎屑；圆外不受影响
// ---------------------------------------------------------------------------
bool test_dig(const std::string& /*materials*/) {
    const uint32_t W = 160, H = 160;
    sim_world* w = make_world(W, H, 77ULL, nullptr);
    CHECK(w != nullptr);
    for (uint32_t y = 0; y < H; ++y) {
        for (uint32_t x = 0; x < W; ++x) sim_world_set_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(y), SIM_MAT_ROCK);
    }
    CHECK(count_material(w, W, H, SIM_MAT_ROCK) == static_cast<uint64_t>(W) * H);
    const int32_t cx = 80, cy = 80;
    const uint32_t r = 12;
    const uint32_t removed = sim_world_dig(w, cx, cy, r);
    CHECK(removed > 0);
    // 圆心必被挖（碎屑沙或空）
    CHECK(sim_world_get_cell(w, cx, cy).material != SIM_MAT_ROCK);
    // 圆内的岩石全部消失；计数与返回值一致（挖掉数 = 半径内原本的岩石数）
    uint32_t expected = 0;
    for (int32_t dy = -static_cast<int32_t>(r); dy <= static_cast<int32_t>(r); ++dy) {
        for (int32_t dx = -static_cast<int32_t>(r); dx <= static_cast<int32_t>(r); ++dx) {
            if (static_cast<int64_t>(dx) * dx + static_cast<int64_t>(dy) * dy >
                static_cast<int64_t>(r) * r) {
                continue;
            }
            ++expected;
            CHECK(sim_world_get_cell(w, cx + dx, cy + dy).material != SIM_MAT_ROCK);
        }
    }
    CHECK(removed == expected);
    // 碎屑：圆内应有沙
    uint64_t sand = 0;
    uint64_t empty = 0;
    for (int32_t dy = -static_cast<int32_t>(r); dy <= static_cast<int32_t>(r); ++dy) {
        for (int32_t dx = -static_cast<int32_t>(r); dx <= static_cast<int32_t>(r); ++dx) {
            if (static_cast<int64_t>(dx) * dx + static_cast<int64_t>(dy) * dy >
                static_cast<int64_t>(r) * r) {
                continue;
            }
            const uint16_t m = sim_world_get_cell(w, cx + dx, cy + dy).material;
            if (m == SIM_MAT_SAND) ++sand;
            if (m == SIM_MAT_EMPTY) ++empty;
        }
    }
    CHECK(sand > 0);
    CHECK(empty > 0);
    CHECK(sand + empty == expected);
    // 圆外（含圆周外 2 格环）仍是岩石
    for (int32_t dy = -static_cast<int32_t>(r) - 2; dy <= static_cast<int32_t>(r) + 2; ++dy) {
        for (int32_t dx = -static_cast<int32_t>(r) - 2; dx <= static_cast<int32_t>(r) + 2; ++dx) {
            const int64_t d2 = static_cast<int64_t>(dx) * dx + static_cast<int64_t>(dy) * dy;
            if (d2 <= static_cast<int64_t>(r + 1) * (r + 1)) continue;
            CHECK(sim_world_get_cell(w, cx + dx, cy + dy).material == SIM_MAT_ROCK);
        }
    }
    // 挖掘事件
    sim_event ev[64];
    const uint32_t n = sim_world_poll_events(w, ev, 64);
    CHECK(n > 0);
    bool saw_dig = false;
    for (uint32_t i = 0; i < n; ++i) {
        if (ev[i].type == SIM_EVENT_DIG) saw_dig = true;
    }
    CHECK(saw_dig);
    sim_world_destroy(w);
    return true;
}

// ---------------------------------------------------------------------------
// 3) 守恒 + 边界：封闭石墙内四种不参与反应的物质总数量不变；世界边界不被写出
// ---------------------------------------------------------------------------
bool test_conservation_and_bounds(const std::string& /*materials*/) {
    const uint32_t W = 200, H = 150;
    sim_world* w = make_world(W, H, 424242ULL, nullptr);
    CHECK(w != nullptr);
    // 四周石墙（1 格厚）
    for (uint32_t x = 0; x < W; ++x) {
        sim_world_set_cell(w, static_cast<int32_t>(x), 0, SIM_MAT_ROCK);
        sim_world_set_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(H) - 1, SIM_MAT_ROCK);
    }
    for (uint32_t y = 0; y < H; ++y) {
        sim_world_set_cell(w, 0, static_cast<int32_t>(y), SIM_MAT_ROCK);
        sim_world_set_cell(w, static_cast<int32_t>(W) - 1, static_cast<int32_t>(y), SIM_MAT_ROCK);
    }
    // 内部：沙/水/油/水银 + 空（无火、无反应、无挖掘 → 数量必须守恒）
    for (uint32_t y = 1; y + 1 < H; ++y) {
        for (uint32_t x = 1; x + 1 < W; ++x) {
            const uint16_t m = pattern_material(static_cast<int32_t>(x), static_cast<int32_t>(y), 424242ULL);
            if (m != SIM_MAT_EMPTY && m != SIM_MAT_FIRE) {
                sim_world_set_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(y), m);
            }
        }
    }
    const uint64_t before[4] = {
        count_material(w, W, H, SIM_MAT_SAND), count_material(w, W, H, SIM_MAT_WATER),
        count_material(w, W, H, SIM_MAT_OIL), count_material(w, W, H, SIM_MAT_QUICKSILVER)};
    CHECK(before[0] > 0);
    CHECK(before[1] > 0);
    for (int i = 0; i < 500; ++i) sim_world_step(w);
    const uint64_t after[4] = {
        count_material(w, W, H, SIM_MAT_SAND), count_material(w, W, H, SIM_MAT_WATER),
        count_material(w, W, H, SIM_MAT_OIL), count_material(w, W, H, SIM_MAT_QUICKSILVER)};
    static const char* names[4] = {"sand", "water", "oil", "quicksilver"};
    for (int i = 0; i < 4; ++i) {
        if (before[i] != after[i]) {
            std::fprintf(stderr, "  conservation FAIL: %s before=%llu after=%llu\n", names[i],
                         static_cast<unsigned long long>(before[i]),
                         static_cast<unsigned long long>(after[i]));
        }
        CHECK(before[i] == after[i]);
    }
    // 边界墙保持完整（物质不会写出边界 / 覆盖墙体）
    for (uint32_t x = 0; x < W; ++x) {
        CHECK(sim_world_get_cell(w, static_cast<int32_t>(x), 0).material == SIM_MAT_ROCK);
        CHECK(sim_world_get_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(H) - 1).material == SIM_MAT_ROCK);
    }
    for (uint32_t y = 0; y < H; ++y) {
        CHECK(sim_world_get_cell(w, 0, static_cast<int32_t>(y)).material == SIM_MAT_ROCK);
        CHECK(sim_world_get_cell(w, static_cast<int32_t>(W) - 1, static_cast<int32_t>(y)).material == SIM_MAT_ROCK);
    }
    // 越界读写安全
    CHECK(sim_world_get_cell(w, -1, 0).material == SIM_MAT_EMPTY);
    CHECK(sim_world_get_cell(w, 0, -1).material == SIM_MAT_EMPTY);
    CHECK(sim_world_get_cell(w, static_cast<int32_t>(W), 0).material == SIM_MAT_EMPTY);
    CHECK(sim_world_set_cell(w, -1, 0, SIM_MAT_SAND) == -1);
    CHECK(sim_world_set_cell(w, 0, static_cast<int32_t>(H), SIM_MAT_SAND) == -1);
    sim_world_destroy(w);
    return true;
}

// ---------------------------------------------------------------------------
// 4) C-SIM API 契约：chunk 载入卸载 / 脏矩形 / 活动区 / 渲染 / 材质表 / 事件
// ---------------------------------------------------------------------------
bool test_api_contract(const std::string& /*materials*/) {
    sim_world* w = make_world(128, 96, 9ULL, nullptr);
    CHECK(w != nullptr);
    CHECK(sim_world_width(w) == 128);
    CHECK(sim_world_height(w) == 96);
    CHECK(sim_world_seed(w) == 9ULL);
    CHECK(sim_world_tick(w) == 0);
    CHECK(sim_world_chunks_x(w) == 2);
    CHECK(sim_world_chunks_y(w) == 2);
    CHECK(sim_world_material_count(w) == SIM_MAT_COUNT_);
    // 材质表
    sim_material_info info{};
    CHECK(sim_world_material_info(w, SIM_MAT_WATER, &info) == 0);
    CHECK_NEAR(info.density, 1.0, 1e-6);
    CHECK(info.state == SIM_STATE_LIQUID);
    CHECK(info.experimental == 0);
    CHECK(sim_world_material_info(w, SIM_MAT_QUICKSILVER, &info) == 0);
    CHECK_NEAR(info.density, 13.6, 1e-6);
    CHECK(sim_world_material_info(w, SIM_MAT_SAND, &info) == 0);
    CHECK(info.experimental == 1);
    CHECK(sim_world_material_id_by_str(w, "water") == SIM_MAT_WATER);
    CHECK(sim_world_material_id_by_str(w, "nope") == 0xFFFF);
    // cell 读写
    CHECK(sim_world_set_cell(w, 10, 10, SIM_MAT_SAND) == 0);
    sim_cell c = sim_world_get_cell(w, 10, 10);
    CHECK(c.material == SIM_MAT_SAND);
    CHECK(c.state == SIM_STATE_POWDER);
    CHECK(sim_world_set_cell(w, 10, 10, 99) == -1);
    // chunk 载入 / 卸载
    CHECK(sim_world_chunk_loaded(w, 0, 0) == 1);
    CHECK(sim_world_unload_chunk(w, 0, 0) == 0);
    CHECK(sim_world_chunk_loaded(w, 0, 0) == 0);
    CHECK(sim_world_get_cell(w, 10, 10).material == SIM_MAT_EMPTY);
    CHECK(sim_world_set_cell(w, 10, 10, SIM_MAT_SAND) == -1);
    CHECK(sim_world_unload_chunk(w, 0, 0) == -1);
    CHECK(sim_world_load_chunk(w, 0, 0) == 0);
    CHECK(sim_world_load_chunk(w, 0, 0) == -1);
    CHECK(sim_world_chunk_loaded(w, 0, 0) == 1);
    CHECK(sim_world_get_cell(w, 10, 10).material == SIM_MAT_EMPTY);
    // 脏矩形
    CHECK(sim_world_set_cell(w, 50, 40, SIM_MAT_WATER) == 0);
    sim_rect d = sim_world_dirty_rect(w, 0);
    CHECK(d.w > 0 && d.h > 0);
    CHECK(50 >= d.x && 50 < d.x + d.w && 40 >= d.y && 40 < d.y + d.h);
    d = sim_world_dirty_rect(w, 1);
    CHECK(d.w > 0);
    d = sim_world_dirty_rect(w, 0);
    CHECK(d.w == 0 && d.h == 0);
    // 活动区
    sim_world_set_active_rect(w, sim_rect{16, 24, 64, 48});
    sim_rect a = sim_world_get_active_rect(w);
    CHECK(a.x == 16 && a.y == 24 && a.w == 64 && a.h == 48);
    sim_world_set_active_rect(w, sim_rect{-20, -20, 40, 40});
    a = sim_world_get_active_rect(w);
    CHECK(a.x == 0 && a.y == 0 && a.w == 20 && a.h == 20);
    sim_world_set_active_rect(w, sim_rect{0, 0, 128, 96});
    // 渲染
    std::vector<uint8_t> pixels(128u * 96u * 4u);
    CHECK(sim_world_render_rgba8(w, sim_rect{0, 0, 128, 96}, pixels.data(), pixels.size()) == 0);
    CHECK(pixels[3] == 255);
    CHECK(sim_world_render_rgba8(w, sim_rect{0, 0, 128, 96}, pixels.data(), 10) == -1);
    // 事件
    for (int32_t y = 70; y < 78; ++y) {
        for (int32_t x = 70; x < 78; ++x) sim_world_set_cell(w, x, y, SIM_MAT_ROCK);
    }
    CHECK(sim_world_dig(w, 73, 73, 3) > 0);
    sim_event ev[128];
    CHECK(sim_world_poll_events(w, ev, 128) > 0);
    // step + hash
    sim_world_step(w);
    CHECK(sim_world_tick(w) == 1);
    CHECK(sim_world_hash(w) != 0);
    sim_tick_stats st{};
    sim_world_last_tick_stats(w, &st);
    CHECK(st.tick == 1);
    sim_world_destroy(w);
    sim_world_destroy(nullptr);  // 必须安全
    return true;
}

// ---------------------------------------------------------------------------
// 5) materials.json 参数：水/水银/岩来自 data/；沙/油/火是 sim 实验物质
// ---------------------------------------------------------------------------
bool test_materials_json(const std::string& materials) {
    if (materials.empty()) {
        std::printf("  SKIP: no --materials path given (builtin defaults tested implicitly)\n");
        return true;
    }
    sim_world* w = make_world(64, 64, 1ULL, materials.c_str());
    CHECK(w != nullptr);
    CHECK(std::strcmp(sim_world_materials_source(w), "data/materials.json") == 0);
    sim_material_info info{};
    CHECK(sim_world_material_info(w, SIM_MAT_WATER, &info) == 0);
    CHECK_NEAR(info.density, 1.0, 1e-6);
    CHECK(info.experimental == 0);
    CHECK(info.color_rgb == 0x4A78C8u);
    CHECK(sim_world_material_info(w, SIM_MAT_QUICKSILVER, &info) == 0);
    CHECK_NEAR(info.density, 13.6, 1e-6);
    CHECK(info.experimental == 0);
    CHECK(sim_world_material_info(w, SIM_MAT_ROCK, &info) == 0);
    CHECK_NEAR(info.density, 2.6, 1e-6);
    CHECK(info.state == SIM_STATE_STATIC);
    CHECK(info.experimental == 0);
    CHECK(sim_world_material_info(w, SIM_MAT_SAND, &info) == 0);
    CHECK(info.experimental == 1);
    CHECK(info.state == SIM_STATE_POWDER);
    CHECK(sim_world_material_info(w, SIM_MAT_OIL, &info) == 0);
    CHECK(info.experimental == 1);
    CHECK(info.flammable == 1);
    CHECK_NEAR(info.density, 0.9, 1e-6);
    CHECK(sim_world_material_info(w, SIM_MAT_FIRE, &info) == 0);
    CHECK(info.experimental == 1);
    CHECK(info.state == SIM_STATE_GAS);
    sim_world_destroy(w);
    return true;
}

struct TestCase {
    const char* name;
    bool (*fn)(const std::string&);
};

}  // namespace

int main(int argc, char** argv) {
    std::string name = "all";
    std::string materials;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--materials" && i + 1 < argc) {
            materials = argv[++i];
        } else if (!a.empty() && a[0] != '-') {
            name = a;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", a.c_str());
            return 2;
        }
    }
    const TestCase tests[] = {
        {"determinism", test_determinism},
        {"dig", test_dig},
        {"conservation", test_conservation_and_bounds},
        {"api", test_api_contract},
        {"materials", test_materials_json},
    };
    int failed = 0;
    int ran = 0;
    for (const TestCase& tc : tests) {
        if (name != "all" && name != tc.name) continue;
        ++ran;
        std::printf("[ RUN  ] %s\n", tc.name);
        const bool ok = tc.fn(materials);
        std::printf("[ %s ] %s\n", ok ? "PASS" : "FAIL", tc.name);
        if (!ok) ++failed;
    }
    if (ran == 0) {
        std::fprintf(stderr, "unknown test: %s\n", name.c_str());
        return 2;
    }
    std::printf("%d/%d tests passed\n", ran - failed, ran);
    return failed == 0 ? 0 : 1;
}
