// sim_core 基准程序：两个场景、固定种子、各 10,000 tick，只计 sim_world_step 的耗时。
//
// 场景定义（与 docs/tech/m0-a-report.md 及 docs/02-m0-plan.md T2 对齐）：
//   worst   : 480x270 世界 = 1 屏，全屏填满流动物质混合（沙/水/油/水银/火，78% 填充）。
//             两种跑法：
//               wake  : 每 tick 前 sim_world_wake_rect(整屏) → 每 tick 处理全部 40 个 chunk。
//                       这是「每 tick 全屏都参与模拟」的保守上界（默认休眠关闭时的成本）。
//               sleep : 不强制唤醒，按引擎默认的 chunk 休眠调度（真实开销）。
//             场景维持：每 150 tick 在屏幕顶部注入一层混合物质 + 随机置换 400 格 + 重新点火，
//             否则 10k tick 内物质会完全沉降、不再是「流动」场景。注入在计时区外执行。
//   typical : 1440x810 = 3x3 屏的矿井灰盒（程序化：岩层/平巷/竖井/洞窟/火室 + 水/油/水银池 +
//             岩台火种）。3x3 屏的 chunk 全部载入；每 tick 只模拟活跃视口 480x270（正中间那屏）。
//             外部事件每 200/250 tick 重新点火种、滴一小股水（计时区外），维持活跃。
//
// 计时：每个 tick 单独 steady_clock 计时，只包住 sim_world_step；注入、唤醒、取统计、写 PNG 都在计时外。
// 输出：stdout 汇总表 + <out>/summary.txt；每 1000 tick 一帧 PNG 到 <out>/。

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "materials.h"
#include "png_writer.h"
#include "sim/c_sim.h"

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

namespace {

constexpr uint32_t kWorstW = 480;
constexpr uint32_t kWorstH = 270;
constexpr uint32_t kTypicalW = 1440;
constexpr uint32_t kTypicalH = 810;
constexpr uint32_t kFrameEvery = 1000;

uint64_t mix64(uint64_t z) {
    z += 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}
uint64_t rng_next(uint64_t* s) {
    *s += 0x9E3779B97F4A7C15ULL;
    return mix64(*s);
}

uint16_t pick_worst_material(uint64_t r) {
    const uint32_t pct = static_cast<uint32_t>(r % 100u);
    if (pct < 24) return SIM_MAT_SAND;
    if (pct < 50) return SIM_MAT_WATER;
    if (pct < 62) return SIM_MAT_OIL;
    if (pct < 70) return SIM_MAT_QUICKSILVER;
    if (pct < 78) return SIM_MAT_FIRE;
    return SIM_MAT_EMPTY;
}

sim_world* create_world(uint32_t w, uint32_t h, uint64_t seed, const char* materials_path) {
    sim_config cfg{};
    cfg.width = w;
    cfg.height = h;
    cfg.seed = seed;
    cfg.chunk_size = 64;
    cfg.fixed_dt = 1.0f / 60.0f;
    cfg.materials_json_path = materials_path;
    return sim_world_create(&cfg);
}

// ------------------------------ worst 场景 ------------------------------

void build_worst(sim_world* w, uint64_t seed) {
    uint64_t rng = seed ^ 0x6A09E667F3BCC909ULL;
    for (uint32_t y = 0; y < kWorstH; ++y) {
        for (uint32_t x = 0; x < kWorstW; ++x) {
            const uint16_t mat = pick_worst_material(rng_next(&rng));
            if (mat != SIM_MAT_EMPTY) {
                sim_world_set_cell(w, static_cast<int32_t>(x), static_cast<int32_t>(y), mat);
            }
        }
    }
    sim_rect full{0, 0, static_cast<int32_t>(kWorstW), static_cast<int32_t>(kWorstH)};
    sim_world_set_active_rect(w, full);
    sim_world_wake_rect(w, full);
}

void inject_worst(sim_world* w, uint64_t tick) {
    if (tick % 150u != 0u) return;
    const sim_rect a = sim_world_get_active_rect(w);
    uint64_t rng = mix64(0x5EED1234ULL ^ (tick * 0x2545F4914F6CDD1DULL));
    // 顶部注入一层混合物质（480*4 = 1920 格），形成持续下落
    for (int i = 0; i < 1920; ++i) {
        const int32_t x = a.x + static_cast<int32_t>(rng_next(&rng) % static_cast<uint32_t>(a.w));
        const int32_t y = a.y + static_cast<int32_t>(rng_next(&rng) % 4u);
        const uint16_t mat = pick_worst_material(rng_next(&rng));
        if (mat != SIM_MAT_EMPTY) sim_world_set_cell(w, x, y, mat);
    }
    // 全屏随机置换 400 格，防止中部完全沉降（压力注入，不代表真实玩法事件）
    for (int i = 0; i < 400; ++i) {
        const int32_t x = a.x + static_cast<int32_t>(rng_next(&rng) % static_cast<uint32_t>(a.w));
        const int32_t y = a.y + static_cast<int32_t>(rng_next(&rng) % static_cast<uint32_t>(a.h));
        const uint16_t mat = pick_worst_material(rng_next(&rng));
        if (mat != SIM_MAT_EMPTY) sim_world_set_cell(w, x, y, mat);
    }
    // 重新点火，保证场景里始终有火在燃烧
    for (int i = 0; i < 30; ++i) {
        const int32_t x = a.x + static_cast<int32_t>(rng_next(&rng) % static_cast<uint32_t>(a.w));
        const int32_t y = a.y + static_cast<int32_t>(rng_next(&rng) % static_cast<uint32_t>(a.h));
        sim_world_set_cell(w, x, y, SIM_MAT_FIRE);
    }
}

// ------------------------------ typical 场景 ------------------------------

void build_typical(sim_world* w, uint64_t seed) {
    const uint32_t W = kTypicalW;
    const uint32_t H = kTypicalH;
    // 1) 岩层 + 程序化挖洞（平巷 / 竖井 / 主洞窟 / 火室），带粗糙边缘和洞内巨石。
    for (uint32_t y = 0; y < H; ++y) {
        const int32_t iy = static_cast<int32_t>(y);
        for (uint32_t x = 0; x < W; ++x) {
            const int32_t ix = static_cast<int32_t>(x);
            const double fx = static_cast<double>(x);
            const double fy = static_cast<double>(y);
            bool solid = true;
            // 主平巷
            const double t1 = 430.0 + 40.0 * std::sin(fx * 0.0083);
            const double h1 = 18.0 + 10.0 * std::sin(fx * 0.0189 + 1.7);
            if (std::fabs(fy - t1) < h1) solid = false;
            // 上层平巷
            const double t2 = 220.0 + 25.0 * std::sin(fx * 0.011 + 0.4);
            if (std::fabs(fy - t2) < 12.0) solid = false;
            // 竖井
            const double sx = 700.0 + 20.0 * std::sin(fy * 0.014);
            if (std::fabs(fx - sx) < 14.0) solid = false;
            // 主洞窟
            const double ex = (fx - 720.0) / 180.0;
            const double ey = (fy - 430.0) / 90.0;
            if (ex * ex + ey * ey < 1.0) solid = false;
            // 火室
            const double ex2 = (fx - 520.0) / 95.0;
            const double ey2 = (fy - 330.0) / 50.0;
            if (ex2 * ex2 + ey2 * ey2 < 1.0) solid = false;
            // 粗糙边缘 + 洞内巨石（粗粒度噪声，确定性）
            const uint32_t n = static_cast<uint32_t>(
                mix64(seed ^ (static_cast<uint64_t>(ix >> 2) * 0x9E3779B1ULL) ^
                      (static_cast<uint64_t>(iy >> 2) * 0x85EBCA77ULL)) >>
                11);
            if (!solid) {
                if ((n & 0xFFFFu) < 900u) solid = true;  // 洞里偶发巨石
            } else {
                if ((n & 0xFFFFu) < 260u) solid = false; // 岩里偶发小缝
            }
            sim_world_set_cell(w, ix, iy, solid ? SIM_MAT_ROCK : SIM_MAT_EMPTY);
        }
    }
    auto fill_if_empty = [w](int32_t x, int32_t y, uint16_t mat) {
        if (sim_world_get_cell(w, x, y).material == SIM_MAT_EMPTY) {
            sim_world_set_cell(w, x, y, mat);
        }
    };
    // 2) 主洞窟里的液体分层：水在最下、油浮在水上、水银沉到水底局部凹坑。
    for (int32_t y = 455; y < 512; ++y) {
        for (int32_t x = 560; x < 890; ++x) fill_if_empty(x, y, SIM_MAT_WATER);
    }
    for (int32_t y = 433; y < 455; ++y) {
        for (int32_t x = 580; x < 870; ++x) fill_if_empty(x, y, SIM_MAT_OIL);
    }
    for (int32_t y = 478; y < 500; ++y) {
        for (int32_t x = 790; x < 860; ++x) {
            if (sim_world_get_cell(w, x, y).material != SIM_MAT_ROCK) {
                sim_world_set_cell(w, x, y, SIM_MAT_QUICKSILVER);
            }
        }
    }
    // 3) 岩台 + 火种（火室中央，视口内可见，持续燃烧）
    for (int32_t y = 330; y <= 337; ++y) {
        for (int32_t x = 486; x <= 548; ++x) sim_world_set_cell(w, x, y, SIM_MAT_ROCK);
    }
    for (int32_t y = 324; y <= 328; ++y) {
        for (int32_t x = 498; x <= 508; ++x) fill_if_empty(x, y, SIM_MAT_FIRE);
    }
    // 4) 油面火源：油层顶部直接点一把，前几百 tick 会看到油池燃烧（典型场景的火焰负载）
    for (int32_t x = 598; x <= 603; ++x) fill_if_empty(x, 432, SIM_MAT_FIRE);
    // 5) 上层平巷的沙堆（会下落、堆积）
    for (int32_t y = 250; y < 292; ++y) {
        for (int32_t x = 840; x < 910; ++x) fill_if_empty(x, y, SIM_MAT_SAND);
    }
    // 6) 活跃视口 = 正中间一屏（480x270）
    sim_rect active{static_cast<int32_t>((W - 480) / 2), static_cast<int32_t>((H - 270) / 2), 480,
                    270};
    sim_world_set_active_rect(w, active);
    sim_world_wake_rect(w, active);
}

void inject_typical(sim_world* w, uint64_t tick) {
    if (tick % 200u == 0u) {
        for (int32_t x = 498; x <= 505; ++x) sim_world_set_cell(w, x, 326, SIM_MAT_FIRE);
    }
    if (tick % 250u == 0u) {
        const int32_t x = 640 + static_cast<int32_t>(tick % 120u);
        sim_world_set_cell(w, x, 372, SIM_MAT_WATER);
    }
}

// ------------------------------ 统计 / 输出 ------------------------------

struct Percentiles {
    double p50 = 0.0, p95 = 0.0, p99 = 0.0;
    double mean = 0.0, min = 0.0, max = 0.0, total_ms = 0.0;
};

Percentiles compute_percentiles(std::vector<double> v) {
    Percentiles p;
    if (v.empty()) return p;
    p.total_ms = 0.0;
    for (double x : v) p.total_ms += x;
    p.mean = p.total_ms / static_cast<double>(v.size());
    std::sort(v.begin(), v.end());
    p.min = v.front();
    p.max = v.back();
    auto at = [&v](double pct) {
        const double idx = std::ceil(pct / 100.0 * static_cast<double>(v.size())) - 1.0;
        const size_t i = idx < 0.0 ? 0u : static_cast<size_t>(idx);
        return v[std::min(i, v.size() - 1)];
    };
    p.p50 = at(50.0);
    p.p95 = at(95.0);
    p.p99 = at(99.0);
    return p;
}

struct RunResult {
    std::string label;
    std::string scenario;
    bool force_wake = false;
    uint32_t ticks = 0;
    Percentiles pct;
    double avg_active_cells = 0.0;
    double avg_awake_chunks = 0.0;
    std::string material_source;
    std::string error;
};

bool write_frame(sim_world* w, const sim_rect& active, const fs::path& dir,
                 const std::string& label, uint64_t tick) {
    std::vector<uint8_t> pixels(static_cast<size_t>(active.w) * static_cast<size_t>(active.h) * 4u);
    if (sim_world_render_rgba8(w, active, pixels.data(), pixels.size()) != 0) return false;
    char name[256];
    std::snprintf(name, sizeof(name), "%s-tick%05" PRIu64 ".png", label.c_str(), tick);
    const fs::path p = dir / name;
    return bench::write_png_rgba8(p.string(), pixels.data(), active.w, active.h);
}

RunResult run_one(const std::string& label, const std::string& scenario, bool force_wake,
                  uint32_t ticks, uint64_t seed, const char* materials_path,
                  const fs::path& frame_dir, bool write_frames) {
    RunResult out;
    out.label = label;
    out.scenario = scenario;
    out.force_wake = force_wake;
    out.ticks = ticks;
    const bool worst = scenario == "worst";
    sim_world* w = create_world(worst ? kWorstW : kTypicalW, worst ? kWorstH : kTypicalH, seed,
                                materials_path);
    if (w == nullptr) {
        out.error = "sim_world_create failed";
        return out;
    }
    if (worst) {
        build_worst(w, seed);
    } else {
        build_typical(w, seed);
    }
    out.material_source = sim_world_materials_source(w);
    const sim_rect active = sim_world_get_active_rect(w);
    std::vector<double> samples(ticks);
    double sum_active = 0.0;
    double sum_awake = 0.0;
    for (uint32_t i = 0; i < ticks; ++i) {
        const uint64_t tick = static_cast<uint64_t>(i) + 1;
        if (worst) {
            inject_worst(w, tick);
        } else {
            inject_typical(w, tick);
        }
        if (force_wake) sim_world_wake_rect(w, active);
        const auto t0 = Clock::now();
        sim_world_step(w);
        const auto t1 = Clock::now();
        samples[i] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        sim_tick_stats st{};
        sim_world_last_tick_stats(w, &st);
        sum_active += static_cast<double>(st.active_cells);
        sum_awake += static_cast<double>(st.awake_chunks);
        if (write_frames && (tick % kFrameEvery == 0)) {
            write_frame(w, active, frame_dir, label, tick);
        }
    }
    out.pct = compute_percentiles(std::move(samples));
    out.avg_active_cells = sum_active / static_cast<double>(ticks);
    out.avg_awake_chunks = sum_awake / static_cast<double>(ticks);
    sim_world_destroy(w);
    return out;
}

void print_row(const RunResult& r) {
    if (!r.error.empty()) {
        std::printf("%-16s ERROR %s\n", r.label.c_str(), r.error.c_str());
        return;
    }
    std::printf("%-16s %-6s ticks=%-5u total=%8.2fs mean=%7.3fms p50=%7.3f p95=%7.3f p99=%7.3f "
                "min=%6.3f max=%8.3f avg_active=%7.0f avg_awake=%5.1f\n",
                r.label.c_str(), r.force_wake ? "wake" : "sleep", r.ticks, r.pct.total_ms / 1000.0,
                r.pct.mean, r.pct.p50, r.pct.p95, r.pct.p99, r.pct.min, r.pct.max,
                r.avg_active_cells, r.avg_awake_chunks);
}

void write_summary(const fs::path& dir, const std::string& materials_path,
                   const std::vector<RunResult>& results, uint64_t seed, uint32_t ticks) {
    std::ofstream f(dir / "summary.txt");
    if (!f) return;
    f << "sim_core bench summary\n";
    f << "contract=" << sim_version() << "\n";
    f << "seed=" << seed << " ticks=" << ticks << "\n";
    f << "materials_path=" << (materials_path.empty() ? "(not found, builtin defaults)" : materials_path)
      << "\n";
    f << "note=开发机数据，非 go/no-go 依据（目标机复测见 docs/tech/m0-a-report.md）\n\n";
    f << "label            mode   ticks  total_s   mean_ms    p50    p95    p99    min     max    "
         "avg_active avg_awake\n";
    char line[512];
    for (const RunResult& r : results) {
        if (!r.error.empty()) {
            f << r.label << " ERROR " << r.error << "\n";
            continue;
        }
        std::snprintf(line, sizeof(line),
                      "%-16s %-6s %-5u %8.2f %8.3f %7.3f %7.3f %7.3f %6.3f %8.3f %9.0f %6.1f\n",
                      r.label.c_str(), r.force_wake ? "wake" : "sleep", r.ticks,
                      r.pct.total_ms / 1000.0, r.pct.mean, r.pct.p50, r.pct.p95, r.pct.p99,
                      r.pct.min, r.pct.max, r.avg_active_cells, r.avg_awake_chunks);
        f << line;
    }
    f << "\nscenario params:\n";
    f << "  worst:   " << kWorstW << "x" << kWorstH
      << " = 1 screen; ~78% filled with sand/water/oil/quicksilver/fire; "
         "wake mode forces all 40 chunks every tick; injection every 150 ticks (outside timing)\n";
    f << "  typical: " << kTypicalW << "x" << kTypicalH << " = 3x3 screens mine greybox; "
         "all 299 chunks loaded; active viewport 480x270 in the middle; "
         "re-ignite/drip every 200/250 ticks (outside timing); "
         "wake mode forces the 40 viewport chunks every tick (sensitivity upper bound)\n";
    f << "  timing: only sim_world_step is measured; 1 tick = 1/60 s.\n";
    f << "\nPNG frames: " << dir.string() << "/*.png\n";
}

void print_usage(const char* argv0) {
    std::printf(
        "usage: %s [options]\n"
        "  --ticks N        ticks per scenario (default 10000)\n"
        "  --seed N         world seed (default 20261115)\n"
        "  --out DIR        output dir for PNG + summary (default bench-frames)\n"
        "  --materials PATH data/materials.json path (default: auto find)\n"
        "  --no-frames      do not write PNG frames\n"
        "  --help\n",
        argv0);
}

}  // namespace

int main(int argc, char** argv) {
    uint32_t ticks = 10000;
    uint64_t seed = 20261115ULL;
    std::string outdir = "bench-frames";
    std::string materials_path;
    bool write_frames = true;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--ticks" && i + 1 < argc) {
            ticks = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
        } else if (a == "--seed" && i + 1 < argc) {
            seed = std::strtoull(argv[++i], nullptr, 10);
        } else if (a == "--out" && i + 1 < argc) {
            outdir = argv[++i];
        } else if (a == "--materials" && i + 1 < argc) {
            materials_path = argv[++i];
        } else if (a == "--no-frames") {
            write_frames = false;
        } else if (a == "--help" || a == "-h") {
            print_usage(argv[0]);
            return 0;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", a.c_str());
            print_usage(argv[0]);
            return 2;
        }
    }
    if (ticks == 0) {
        std::fprintf(stderr, "--ticks must be > 0\n");
        return 2;
    }
    if (materials_path.empty()) {
        materials_path = simcore::find_materials_json(argv[0]);
    }
    std::error_code ec;
    fs::create_directories(fs::path(outdir), ec);
    std::printf("sim_core bench  contract=%s\n", sim_version());
    std::printf("materials_path=%s\n",
                materials_path.empty() ? "(not found; builtin defaults)" : materials_path.c_str());
    if (!materials_path.empty() && !fs::is_regular_file(materials_path, ec)) {
        std::fprintf(stderr, "warning: materials file not found: %s (builtin defaults)\n",
                     materials_path.c_str());
        materials_path.clear();
    }
    const fs::path frame_dir(outdir);
    std::vector<RunResult> results;
    results.push_back(
        run_one("worst-wake", "worst", true, ticks, seed,
                materials_path.empty() ? nullptr : materials_path.c_str(), frame_dir, write_frames));
    results.push_back(run_one("worst-sleep", "worst", false, ticks, seed,
                              materials_path.empty() ? nullptr : materials_path.c_str(), frame_dir,
                              write_frames));
    results.push_back(run_one("typical-sleep", "typical", false, ticks, seed,
                              materials_path.empty() ? nullptr : materials_path.c_str(), frame_dir,
                              write_frames));
    // 敏感性：typical 场景强制每 tick 唤醒整个视口（不依赖 chunk 休眠），给典型场景一个上界。
    results.push_back(run_one("typical-wake", "typical", true, ticks, seed,
                              materials_path.empty() ? nullptr : materials_path.c_str(), frame_dir,
                              false));
    std::printf("\n");
    for (const RunResult& r : results) print_row(r);
    std::printf("\n");
    // 关键判定行（开发机数据，非 go/no-go 依据）
    const RunResult& worst_wake = results[0];
    const RunResult& worst_sleep = results[1];
    const RunResult& typical_sleep = results[2];
    const RunResult& typical_wake = results[3];
    std::printf("worst p95  = %.3f ms (wake/保守上界), %.3f ms (sleep/默认) | D4 目标 <= 6.000 ms\n",
                worst_wake.pct.p95, worst_sleep.pct.p95);
    std::printf("typical p95= %.3f ms (sleep/默认), %.3f ms (wake/敏感性) | D4 目标 <= 2.000 ms\n",
                typical_sleep.pct.p95, typical_wake.pct.p95);
    write_summary(frame_dir, materials_path, results, seed, ticks);
    std::printf("summary written: %s\n", (frame_dir / "summary.txt").string().c_str());
    bool ok = true;
    for (const RunResult& r : results) {
        if (!r.error.empty()) ok = false;
    }
    return ok ? 0 : 1;
}
