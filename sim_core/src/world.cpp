// sim_core 世界实现：chunk + 脏矩形 + 5 物质 + 挖掘 + 事件 + 渲染。
// 契约见 include/sim/c_sim.h；材质参数见 materials.h/.cpp。
//
// 实现要点（性能相关，改动前请读 docs/tech/m0-a-report.md 的「局限」）：
//  - 单线程、确定性：所有随机性 = seed + cell 坐标 + tick 的整数 hash，无全局 RNG 序列。
//  - 每 chunk 64x64 cell、4 字节/cell（mat/aux/stamp/pad），按 chunk 惰性休眠：
//    只有上一 tick 有写入的 chunk 才参与下一 tick，写 chunk 边界时唤醒邻居。
//  - 每个 tick 先取上一 tick 的唤醒列表，再清空；新写入的 chunk 进入下一 tick 列表。
//  - 活动区边界按墙处理，物质不流出/流入（保证守恒，避免休眠区里物质悬空）。
//  - 扫描顺序：行从下往上（粉末/液体不会一 tick 下落多格），列方向按 tick 奇偶交替。
//    cell.stamp = 本 tick 序号低 8 位，防止同一 cell 一 tick 内被移动两次。

#include "sim/c_sim.h"

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <vector>

#include "materials.h"

namespace {

constexpr int kChunk = static_cast<int>(SIM_CHUNK_SIZE);
constexpr int kChunkCells = kChunk * kChunk;
constexpr uint32_t kEventCap = 4096;
constexpr uint64_t kSaltDir = 0x1122334455667788ULL;
constexpr uint64_t kSaltIgnite = 0xA5A5F00DC0FFEE01ULL;
constexpr uint64_t kSaltDebris = 0x0DEB715E0BADC0DEULL;
constexpr uint64_t kSaltFireLife = 0xF11E11FE12345678ULL;
constexpr uint64_t kSaltRender = 0x5EED5EED5EED5EEDULL;
constexpr uint64_t kSaltReact = 0x91E10DA5C79E7B1DULL;
constexpr uint64_t kSaltGasDrift = 0x6A09E667BB67AE85ULL;
constexpr float kFireSourceHeat = 400.0f;
constexpr float kBurningFuelHeat = 350.0f;
constexpr float kIgniteBaseRate = 0.02f;
constexpr float kIgniteTempScale = 200.0f;
constexpr float kSteamCondenseChance = 0.25f;
constexpr uint32_t kMaxBlackPowderPerTick = 4;

inline uint64_t mix64(uint64_t z) {
    z += 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

struct Cell {
    uint8_t mat;   // sim_material
    uint8_t aux;   // 火：剩余寿命 tick
    uint8_t stamp; // 本 tick 低 8 位；== tick8 表示本 tick 已写过
    uint8_t pad;
};

struct Chunk {
    std::vector<Cell> cells; // kChunkCells 个，仅 loaded 时有效
    bool loaded = false;
};

}  // namespace

// 契约头文件里的 typedef struct sim_world sim_world; 这里给出定义（不透明指针）。
struct sim_world {
    // --- 配置 ---
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t chunks_x = 0;
    uint32_t chunks_y = 0;
    uint64_t seed = 0;
    uint64_t tick = 0; // 下一个 tick 序号从 1 开始
    float fixed_dt = 1.0f / 60.0f;

    std::vector<Chunk> chunks;
    simcore::MaterialTable materials;

    // 材质参数快查表（step 热路径）
    std::array<uint8_t, SIM_MAT_COUNT_> mat_state{};
    std::array<float, SIM_MAT_COUNT_> mat_density{};
    std::array<uint8_t, SIM_MAT_COUNT_> mat_flammable{};
    std::array<uint8_t, SIM_MAT_COUNT_> mat_spread{};
    std::array<uint8_t, SIM_MAT_COUNT_> mat_life_min{};
    std::array<uint8_t, SIM_MAT_COUNT_> mat_life_max{};
    std::array<float, SIM_MAT_COUNT_> mat_ignite{};
    std::array<float, SIM_MAT_COUNT_> mat_ignition_temp{};
    std::array<uint16_t, SIM_MAT_COUNT_> mat_burn_time{};
    std::array<uint16_t, SIM_MAT_COUNT_> mat_burn_product{};
    uint32_t tick_black_powder_blasts = 0;

    // 活动区 [ax0, ax1) x [ay0, ay1)，已裁剪到世界内。
    int32_t ax0 = 0;
    int32_t ay0 = 0;
    int32_t ax1 = 0;
    int32_t ay1 = 0;

    // 脏矩形（自上次 clear=1 查询以来）
    int32_t dminx = 0;
    int32_t dminy = 0;
    int32_t dmaxx = -1;
    int32_t dmaxy = -1;
    bool dirty_valid = false;

    // 唤醒调度
    std::vector<uint32_t> awake_cur;
    std::vector<uint32_t> awake_next;
    std::vector<uint8_t> next_mark;

    // 事件环形缓冲
    std::vector<sim_event> events;
    uint32_t ev_head = 0;
    uint32_t ev_count = 0;

    // 统计
    sim_tick_stats last_stats{};
    uint32_t tick_events = 0;

    // ---------------- 基础工具 ----------------
    inline uint64_t cell_random(int32_t x, int32_t y, uint64_t salt) const {
        uint64_t h = seed;
        h ^= (static_cast<uint64_t>(static_cast<uint32_t>(x)) * 0xD6E8FEB86659FD93ULL);
        h ^= (static_cast<uint64_t>(static_cast<uint32_t>(y)) << 32);
        h ^= salt;
        return mix64(h);
    }
    inline uint64_t tick_random(int32_t x, int32_t y, uint64_t salt) const {
        return mix64(cell_random(x, y, salt) ^ (tick * 0xBF58476D1CE4E5B9ULL));
    }
    inline float rand01(int32_t x, int32_t y, uint64_t salt) const {
        return static_cast<float>(tick_random(x, y, salt) >> 40) * (1.0f / 16777216.0f);
    }

    inline bool in_active(int32_t x, int32_t y) const {
        return x >= ax0 && x < ax1 && y >= ay0 && y < ay1;
    }

    inline uint32_t chunk_index_xy(int32_t x, int32_t y) const {
        return (static_cast<uint32_t>(y) >> 6) * chunks_x + (static_cast<uint32_t>(x) >> 6);
    }

    inline bool chunk_loaded_at(int32_t x, int32_t y) const {
        return chunks[chunk_index_xy(x, y)].loaded;
    }

    inline Cell& cell_at(int32_t x, int32_t y) {
        return chunks[chunk_index_xy(x, y)]
            .cells[((static_cast<uint32_t>(y) & 63u) << 6) | (static_cast<uint32_t>(x) & 63u)];
    }
    inline const Cell& cell_at(int32_t x, int32_t y) const {
        return chunks[chunk_index_xy(x, y)]
            .cells[((static_cast<uint32_t>(y) & 63u) << 6) | (static_cast<uint32_t>(x) & 63u)];
    }

    inline void wake_chunk(uint32_t ci) {
        if (ci < next_mark.size() && next_mark[ci] == 0) {
            next_mark[ci] = 1;
            awake_next.push_back(ci);
        }
    }
    inline void wake_chunk_xy(int32_t cx, int32_t cy) {
        if (cx >= 0 && cy >= 0 && cx < static_cast<int32_t>(chunks_x) &&
            cy < static_cast<int32_t>(chunks_y)) {
            wake_chunk(static_cast<uint32_t>(cy) * chunks_x + static_cast<uint32_t>(cx));
        }
    }

    // 一次 cell 写入：更新脏矩形 + 唤醒本 chunk 与（需要时）8 邻居 chunk。
    inline void touch(int32_t x, int32_t y) {
        if (!dirty_valid) {
            dminx = dmaxx = x;
            dminy = dmaxy = y;
            dirty_valid = true;
        } else {
            if (x < dminx) dminx = x;
            if (x > dmaxx) dmaxx = x;
            if (y < dminy) dminy = y;
            if (y > dmaxy) dmaxy = y;
        }
        const uint32_t cx = static_cast<uint32_t>(x) >> 6;
        const uint32_t cy = static_cast<uint32_t>(y) >> 6;
        wake_chunk(cy * chunks_x + cx);
        const int32_t lx = x & 63;
        const int32_t ly = y & 63;
        if (lx == 0) wake_chunk_xy(static_cast<int32_t>(cx) - 1, static_cast<int32_t>(cy));
        if (lx == 63) wake_chunk_xy(static_cast<int32_t>(cx) + 1, static_cast<int32_t>(cy));
        if (ly == 0) wake_chunk_xy(static_cast<int32_t>(cx), static_cast<int32_t>(cy) - 1);
        if (ly == 63) wake_chunk_xy(static_cast<int32_t>(cx), static_cast<int32_t>(cy) + 1);
        if (lx == 0 && ly == 0) wake_chunk_xy(static_cast<int32_t>(cx) - 1, static_cast<int32_t>(cy) - 1);
        if (lx == 63 && ly == 0) wake_chunk_xy(static_cast<int32_t>(cx) + 1, static_cast<int32_t>(cy) - 1);
        if (lx == 0 && ly == 63) wake_chunk_xy(static_cast<int32_t>(cx) - 1, static_cast<int32_t>(cy) + 1);
        if (lx == 63 && ly == 63) wake_chunk_xy(static_cast<int32_t>(cx) + 1, static_cast<int32_t>(cy) + 1);
    }

    inline void mark_dirty_rect(int32_t x, int32_t y, int32_t w, int32_t h) {
        if (w <= 0 || h <= 0) return;
        if (!dirty_valid) {
            dminx = x;
            dminy = y;
            dmaxx = x + w - 1;
            dmaxy = y + h - 1;
            dirty_valid = true;
        } else {
            if (x < dminx) dminx = x;
            if (y < dminy) dminy = y;
            if (x + w - 1 > dmaxx) dmaxx = x + w - 1;
            if (y + h - 1 > dmaxy) dmaxy = y + h - 1;
        }
    }

    inline void push_event(uint16_t type, uint16_t mat, int32_t x, int32_t y, uint16_t aux) {
        if (events.size() < kEventCap) events.resize(kEventCap);
        sim_event& e = events[ev_head];
        e.type = type;
        e.material = mat;
        e.x = x;
        e.y = y;
        e.aux = aux;
        e.pad = 0;
        ev_head = (ev_head + 1) % kEventCap;
        if (ev_count < kEventCap) ++ev_count;
        ++tick_events;
    }

    // 目标格能否被 mover 占据（mover_state：POWDER/LIQUID）。
    inline bool can_displace(int32_t x, int32_t y, uint8_t mover_mat, uint8_t mover_state) const {
        if (x < ax0 || x >= ax1 || y < ay0 || y >= ay1) return false;
        const uint32_t ci = chunk_index_xy(x, y);
        if (!chunks[ci].loaded) return false;
        const Cell& t = chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                          (static_cast<uint32_t>(x) & 63u)];
        if (t.mat == SIM_MAT_EMPTY) return true;
        const uint8_t ts = mat_state[t.mat];
        if (ts == SIM_STATE_GAS) return mover_state != SIM_STATE_GAS; // 液体/粉末排开火
        if (ts == SIM_STATE_LIQUID) {
            if (mover_state != SIM_STATE_LIQUID && mover_state != SIM_STATE_POWDER) return false;
            return mat_density[mover_mat] > mat_density[t.mat] + 1e-4f;
        }
        return false;
    }

    inline bool empty_at(int32_t x, int32_t y) const {
        if (x < ax0 || x >= ax1 || y < ay0 || y >= ay1) return false;
        const uint32_t ci = chunk_index_xy(x, y);
        if (!chunks[ci].loaded) return false;
        return chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                 (static_cast<uint32_t>(x) & 63u)]
                   .mat == SIM_MAT_EMPTY;
    }

    // 粒子从 (fx,fy) 移到 (tx,ty)：目标空则搬，非空则交换（用于密度沉浮）。
    inline void move_to(int32_t fx, int32_t fy, int32_t tx, int32_t ty) {
        Cell& src = cell_at(fx, fy);
        Cell& dst = cell_at(tx, ty);
        const uint8_t sm = src.mat;
        const uint8_t sa = src.aux;
        if (dst.mat == SIM_MAT_EMPTY) {
            dst.mat = sm;
            dst.aux = sa;
            src.mat = SIM_MAT_EMPTY;
            src.aux = 0;
        } else {
            const uint8_t dm = dst.mat;
            const uint8_t da = dst.aux;
            dst.mat = sm;
            dst.aux = sa;
            src.mat = dm;
            src.aux = da;
        }
        const uint8_t t8 = static_cast<uint8_t>(tick);
        dst.stamp = t8;
        src.stamp = t8;
        last_stats.changed_cells += 2;
        touch(fx, fy);
        touch(tx, ty);
    }

    inline void set_cell_raw(int32_t x, int32_t y, uint8_t mat, uint8_t aux) {
        Cell& c = cell_at(x, y);
        c.mat = mat;
        c.aux = aux;
        c.stamp = static_cast<uint8_t>(tick);
        ++last_stats.changed_cells;
        touch(x, y);
    }

    // ---------------- 反应与热/火工具（C-SIM v3） ----------------
    inline uint8_t gas_initial_life(int32_t x, int32_t y, uint16_t mat) const {
        if (mat >= SIM_MAT_COUNT_) return 60;
        const int32_t lo = mat_life_min[mat];
        const int32_t hi = mat_life_max[mat];
        if (hi <= lo) return static_cast<uint8_t>(std::max(1, lo));
        const uint32_t span = static_cast<uint32_t>(hi - lo + 1);
        return static_cast<uint8_t>(
            lo + static_cast<int32_t>(cell_random(x, y, kSaltFireLife) % span));
    }

    inline bool spawn_gas_near(int32_t x, int32_t y, uint8_t gas_mat) {
        const int32_t ox[5] = {x, x - 1, x + 1, x - 1, x + 1};
        const int32_t oy[5] = {y - 1, y - 1, y - 1, y, y};
        for (int k = 0; k < 5; ++k) {
            const int32_t nx = ox[k];
            const int32_t ny = oy[k];
            if (!empty_at(nx, ny)) continue;
            set_cell_raw(nx, ny, gas_mat, gas_initial_life(nx, ny, gas_mat));
            return true;
        }
        return false;
    }

    inline bool has_black_powder_mix(int32_t cx, int32_t cy) const {
        bool has_n = false;
        bool has_s = false;
        bool has_c = false;
        const int32_t x0 = std::max(ax0, cx - 3);
        const int32_t x1 = std::min(ax1 - 1, cx + 3);
        const int32_t y0 = std::max(ay0, cy - 3);
        const int32_t y1 = std::min(ay1 - 1, cy + 3);
        for (int32_t y = y0; y <= y1; ++y) {
            for (int32_t x = x0; x <= x1; ++x) {
                const uint32_t ci = chunk_index_xy(x, y);
                if (!chunks[ci].loaded) continue;
                const uint8_t m =
                    chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                     (static_cast<uint32_t>(x) & 63u)]
                        .mat;
                if (m == SIM_MAT_SALTPETER) has_n = true;
                else if (m == SIM_MAT_SULFUR) has_s = true;
                else if (m == SIM_MAT_COAL) has_c = true;
                if (has_n && has_s && has_c) return true;
            }
        }
        return false;
    }

    // r-black-powder（priority 10）：消耗半径内硝+硫+煤并炸开坑洞、喷火与烟。
    void trigger_black_powder(int32_t cx, int32_t cy) {
        if (tick_black_powder_blasts >= kMaxBlackPowderPerTick) return;
        ++tick_black_powder_blasts;
        constexpr int32_t kBlastR = 16;
        constexpr int32_t kBlastR2 = kBlastR * kBlastR;
        const int32_t x0 = std::max<int32_t>(0, cx - kBlastR);
        const int32_t x1 = std::min<int32_t>(static_cast<int32_t>(width) - 1, cx + kBlastR);
        const int32_t y0 = std::max<int32_t>(0, cy - kBlastR);
        const int32_t y1 = std::min<int32_t>(static_cast<int32_t>(height) - 1, cy + kBlastR);
        for (int32_t y = y0; y <= y1; ++y) {
            const int32_t dy = y - cy;
            for (int32_t x = x0; x <= x1; ++x) {
                const int32_t dx = x - cx;
                const int32_t d2 = dx * dx + dy * dy;
                if (d2 > kBlastR2) continue;
                const uint32_t ci = chunk_index_xy(x, y);
                if (!chunks[ci].loaded) continue;
                Cell& c = chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                           (static_cast<uint32_t>(x) & 63u)];
                const uint8_t m = c.mat;
                const bool is_bp_mat =
                    (m == SIM_MAT_SALTPETER || m == SIM_MAT_SULFUR || m == SIM_MAT_COAL);
                const uint8_t st = mat_state[m];
                if (m != SIM_MAT_EMPTY && !is_bp_mat && st != SIM_STATE_STATIC &&
                    st != SIM_STATE_POWDER) {
                    continue;
                }
                const uint32_t roll = static_cast<uint32_t>(tick_random(x, y, kSaltReact) & 0xFFu);
                if (d2 <= 100 && roll < 70u) {
                    set_cell_raw(x, y, SIM_MAT_FIRE, gas_initial_life(x, y, SIM_MAT_FIRE));
                } else if (d2 <= 144 && roll < 115u) {
                    set_cell_raw(x, y, SIM_MAT_SMOKE, gas_initial_life(x, y, SIM_MAT_SMOKE));
                } else if (!is_bp_mat && d2 > 144 && st == SIM_STATE_STATIC && roll < 155u) {
                    set_cell_raw(x, y, SIM_MAT_SAND, 0);
                } else {
                    set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
                }
            }
        }
        wake_rect_impl(sim_rect{cx - kBlastR - 4, cy - kBlastR - 4, 2 * kBlastR + 9, 2 * kBlastR + 9});
        push_event(SIM_EVENT_REACTION, SIM_MAT_SALTPETER, cx, cy, SIM_REACT_BLACK_POWDER);
    }

    // 局部热判定（priority 10 黑火药 > priority 1 硫磺毒烟 > priority 0 可燃物点燃）。
    // 返回 1 表示本格发生了反应或点燃。
    inline uint32_t apply_heat_to_cell(int32_t nx, int32_t ny, float heat_temp, bool burst) {
        if (nx < 0 || ny < 0 || nx >= static_cast<int32_t>(width) ||
            ny >= static_cast<int32_t>(height)) {
            return 0;
        }
        if (!burst && !in_active(nx, ny)) return 0;
        const uint32_t ci = chunk_index_xy(nx, ny);
        if (!chunks[ci].loaded) return 0;
        Cell& n = chunks[ci].cells[((static_cast<uint32_t>(ny) & 63u) << 6) |
                                   (static_cast<uint32_t>(nx) & 63u)];
        const uint8_t nm = n.mat;
        if (nm == SIM_MAT_EMPTY) return 0;

        // Priority 10: r-black-powder (heat >= 120, saltpeter + sulfur + coal)
        if (heat_temp >= 120.0f &&
            (nm == SIM_MAT_SALTPETER || nm == SIM_MAT_SULFUR || nm == SIM_MAT_COAL)) {
            if (has_black_powder_mix(nx, ny)) {
                trigger_black_powder(nx, ny);
                return 1;
            }
        }

        // Priority 1: r-sulfur-toxic-smoke (heat >= 80, consumes: [])
        if (nm == SIM_MAT_SULFUR && heat_temp >= 80.0f) {
            const float smoke_p = burst ? 0.85f : 0.14f;
            if (rand01(nx, ny, kSaltReact) < smoke_p) {
                if (spawn_gas_near(nx, ny, SIM_MAT_TOXIC_SMOKE)) {
                    push_event(SIM_EVENT_REACTION, SIM_MAT_SULFUR, nx, ny,
                               SIM_REACT_SULFUR_TOXIC_SMOKE);
                    push_event(SIM_EVENT_SMOKE, SIM_MAT_TOXIC_SMOKE, nx, ny, 0);
                }
            }
            // 若温度未达硫磺燃点（250°），只冒毒烟、不点燃消耗硫磺
            if (heat_temp < mat_ignition_temp[SIM_MAT_SULFUR]) {
                return 1;
            }
        }

        // Priority 0: 可燃材质点燃（油直接变火；煤/硫磺/竹木进入 aux 燃烧态）
        if (mat_flammable[nm] == 0) return 0;
        const float ign_t = mat_ignition_temp[nm];
        if (ign_t > 0.0f && heat_temp < ign_t) return 0;
        if (mat_burn_time[nm] == 0) {
            // 油等瞬燃液体：沿用 v1 5%/tick（burst 下高概率）
            const float p = burst ? 0.85f : mat_ignite[nm];
            if (p <= 0.0f) return 0;
            if (rand01(nx, ny, kSaltIgnite) < p) {
                ignite_cell(nx, ny, nm);
                return 1;
            }
            return 0;
        }
        // 固体/粉末燃料（竹木/煤/硫磺）：aux > 0 表示已在燃烧
        if (n.aux > 0) return 0;
        float mult = (heat_temp - ign_t) / kIgniteTempScale;
        mult = std::min(2.0f, std::max(0.25f, mult));
        const float p = burst ? 0.85f : (kIgniteBaseRate * mult);
        if (rand01(nx, ny, kSaltIgnite) < p) {
            const uint16_t bt = mat_burn_time[nm];
            n.aux = static_cast<uint8_t>(bt > 255u ? 255u : std::max<uint16_t>(bt, 1u));
            n.stamp = static_cast<uint8_t>(tick);
            ++last_stats.changed_cells;
            touch(nx, ny);
            push_event(SIM_EVENT_FIRE_IGNITED, nm, nx, ny, n.aux);
            return 1;
        }
        return 0;
    }

    // 燃烧中的固体/粉末燃料（竹木/煤/硫磺，aux > 0）。返回 true 表示本格已转化/消亡。
    inline bool process_burning_fuel(int32_t x, int32_t y, Cell& c) {
        const uint8_t m = c.mat;
        // 遇水立刻熄灭并冒蒸汽
        if (neighbor_has_water(x, y)) {
            c.aux = 0;
            c.stamp = static_cast<uint8_t>(tick);
            ++last_stats.changed_cells;
            touch(x, y);
            push_event(SIM_EVENT_FIRE_EXTINGUISHED, m, x, y, 0);
            if (spawn_gas_near(x, y, SIM_MAT_STEAM)) {
                push_event(SIM_EVENT_STEAM, SIM_MAT_STEAM, x, y, 0);
            }
            return false;
        }
        // 作为局部热源向 4 邻域传热（支持平铺煤/硫堆与竹木蔓延）
        const int32_t ox[4] = {x - 1, x + 1, x, x};
        const int32_t oy[4] = {y, y, y - 1, y + 1};
        for (int k = 0; k < 4; ++k) {
            apply_heat_to_cell(ox[k], oy[k], kBurningFuelHeat, false);
        }
        // 上方有空位时偶发冒出一朵跳动火苗
        if (rand01(x, y, kSaltGasDrift) < 0.10f) {
            spawn_gas_near(x, y, SIM_MAT_FIRE);
        }
        // 燃烧计时递减；归零时转为燃尽产物
        if (c.aux <= 1) {
            const uint16_t prod = mat_burn_product[m];
            if (m == SIM_MAT_BAMBOO && prod == SIM_MAT_COAL) {
                set_cell_raw(x, y, SIM_MAT_COAL, 0);
                push_event(SIM_EVENT_REACTION, SIM_MAT_BAMBOO, x, y, SIM_REACT_BAMBOO_BURN);
                if (spawn_gas_near(x, y, SIM_MAT_SMOKE)) {
                    push_event(SIM_EVENT_SMOKE, SIM_MAT_SMOKE, x, y, 0);
                }
            } else if (prod == SIM_MAT_SMOKE || prod == SIM_MAT_TOXIC_SMOKE) {
                const uint8_t gm = static_cast<uint8_t>(prod);
                set_cell_raw(x, y, gm, gas_initial_life(x, y, gm));
                push_event(SIM_EVENT_SMOKE, gm, x, y, 0);
            } else {
                set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
            }
            push_event(SIM_EVENT_FIRE_EXTINGUISHED, m, x, y, 0);
            return true;
        }
        --c.aux;
        ++last_stats.changed_cells;
        touch(x, y);
        return false;
    }

    // ---------------- 运动规则 ----------------
    inline void process_powder(int32_t x, int32_t y, uint8_t mat) {
        Cell& c = cell_at(x, y);
        // 燃烧中的煤/硫磺先演化燃烧；燃尽转为气体后不再按粉末下落
        if (c.aux > 0 && mat_burn_time[mat] > 0) {
            if (process_burning_fuel(x, y, c)) return;
        }
        // 接触反应：r-lime-steam（石灰 + 水 -> 蒸汽，全消耗）
        if (mat == SIM_MAT_LIME) {
            const int32_t ox[4] = {x - 1, x + 1, x, x};
            const int32_t oy[4] = {y, y, y - 1, y + 1};
            for (int k = 0; k < 4; ++k) {
                const int32_t nx = ox[k], ny = oy[k];
                if (!in_active(nx, ny) || !chunk_loaded_at(nx, ny)) continue;
                if (cell_at(nx, ny).mat == SIM_MAT_WATER) {
                    set_cell_raw(x, y, SIM_MAT_STEAM, gas_initial_life(x, y, SIM_MAT_STEAM));
                    set_cell_raw(nx, ny, SIM_MAT_STEAM, gas_initial_life(nx, ny, SIM_MAT_STEAM));
                    push_event(SIM_EVENT_REACTION, SIM_MAT_LIME, x, y, SIM_REACT_LIME_STEAM);
                    push_event(SIM_EVENT_STEAM, SIM_MAT_STEAM, x, y, 0);
                    return;
                }
            }
        }
        // 接触反应：r-rice-purify（糯米 + 阴气 -> 清除阴气，保留糯米）
        if (mat == SIM_MAT_GLUTINOUS_RICE) {
            const int32_t ox[4] = {x - 1, x + 1, x, x};
            const int32_t oy[4] = {y, y, y - 1, y + 1};
            for (int k = 0; k < 4; ++k) {
                const int32_t nx = ox[k], ny = oy[k];
                if (!in_active(nx, ny) || !chunk_loaded_at(nx, ny)) continue;
                if (cell_at(nx, ny).mat == SIM_MAT_YIN_QI) {
                    set_cell_raw(nx, ny, SIM_MAT_EMPTY, 0);
                    push_event(SIM_EVENT_REACTION, SIM_MAT_GLUTINOUS_RICE, nx, ny,
                               SIM_REACT_RICE_PURIFY);
                }
            }
        }
        if (can_displace(x, y + 1, mat, SIM_STATE_POWDER)) {
            move_to(x, y, x, y + 1);
            return;
        }
        const int32_t dir = (cell_random(x, y, kSaltDir) & 1) ? 1 : -1;
        if (can_displace(x + dir, y + 1, mat, SIM_STATE_POWDER)) {
            move_to(x, y, x + dir, y + 1);
            return;
        }
        if (can_displace(x - dir, y + 1, mat, SIM_STATE_POWDER)) {
            move_to(x, y, x - dir, y + 1);
        }
    }

    inline void process_liquid(int32_t x, int32_t y, uint8_t mat) {
        if (can_displace(x, y + 1, mat, SIM_STATE_LIQUID)) {
            move_to(x, y, x, y + 1);
            return;
        }
        const int32_t dir = (tick_random(x, y, kSaltDir) & 1ULL) ? 1 : -1;
        if (can_displace(x + dir, y + 1, mat, SIM_STATE_LIQUID)) {
            move_to(x, y, x + dir, y + 1);
            return;
        }
        if (can_displace(x - dir, y + 1, mat, SIM_STATE_LIQUID)) {
            move_to(x, y, x - dir, y + 1);
            return;
        }
        // 横向找平：先沿 dir 探索，受阻则立刻尝试反方向 -dir，避免单侧遇墙时僵直成固体。
        const int32_t spread = static_cast<int32_t>(mat_spread[mat]);
        auto try_horiz = [&](int32_t step_dir) -> int32_t {
            int32_t reach = 0;
            for (int32_t s = 1; s <= spread; ++s) {
                const int32_t nx = x + step_dir * s;
                if (!can_displace(nx, y, mat, SIM_STATE_LIQUID)) break;
                reach = s;
                if (!empty_at(nx, y)) break; // 置换轻液/气体只跨一步
                if (can_displace(nx, y + 1, mat, SIM_STATE_LIQUID)) break; // 到边缘立即下滑
            }
            return reach;
        };
        int32_t reach = try_horiz(dir);
        if (reach > 0) {
            move_to(x, y, x + dir * reach, y);
            return;
        }
        reach = try_horiz(-dir);
        if (reach > 0) {
            move_to(x, y, x - dir * reach, y);
        }
    }

    inline bool neighbor_has_water(int32_t x, int32_t y) const {
        if (x > ax0 && chunk_loaded_at(x - 1, y) && cell_at(x - 1, y).mat == SIM_MAT_WATER) return true;
        if (x + 1 < ax1 && chunk_loaded_at(x + 1, y) && cell_at(x + 1, y).mat == SIM_MAT_WATER) return true;
        if (y > ay0 && chunk_loaded_at(x, y - 1) && cell_at(x, y - 1).mat == SIM_MAT_WATER) return true;
        if (y + 1 < ay1 && chunk_loaded_at(x, y + 1) && cell_at(x, y + 1).mat == SIM_MAT_WATER) return true;
        return false;
    }

    // 把 (x,y) 处的可燃液体（如油）换成火。material = 被烧掉的物质 id。
    inline void ignite_cell(int32_t x, int32_t y, uint8_t material) {
        const uint8_t life = gas_initial_life(x, y, SIM_MAT_FIRE);
        set_cell_raw(x, y, SIM_MAT_FIRE, life);
        push_event(SIM_EVENT_FIRE_IGNITED, material, x, y, life);
    }

    inline void process_fire(int32_t x, int32_t y) {
        Cell& c = cell_at(x, y);
        const uint8_t life = c.aux;
        // 水浇灭 -> 45% 产蒸汽（水本身不消耗）
        if (neighbor_has_water(x, y)) {
            if (rand01(x, y, kSaltReact) < 0.45f) {
                set_cell_raw(x, y, SIM_MAT_STEAM, gas_initial_life(x, y, SIM_MAT_STEAM));
                push_event(SIM_EVENT_STEAM, SIM_MAT_STEAM, x, y, 0);
            } else {
                set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
            }
            push_event(SIM_EVENT_FIRE_EXTINGUISHED, SIM_MAT_FIRE, x, y, life);
            return;
        }
        // 热源（400°C）对 4 邻域执行反应表（黑火药 > 硫磺毒烟 > 可燃物点燃）
        const int32_t ox[4] = {x - 1, x + 1, x, x};
        const int32_t oy[4] = {y, y, y - 1, y + 1};
        for (int k = 0; k < 4; ++k) {
            apply_heat_to_cell(ox[k], oy[k], kFireSourceHeat, false);
        }
        // 寿命：烧完 25% 变烟、其余变空
        if (life <= 1) {
            if (rand01(x, y, kSaltReact) < 0.25f) {
                set_cell_raw(x, y, SIM_MAT_SMOKE, gas_initial_life(x, y, SIM_MAT_SMOKE));
                push_event(SIM_EVENT_SMOKE, SIM_MAT_SMOKE, x, y, 0);
            } else {
                set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
            }
            push_event(SIM_EVENT_FIRE_EXTINGUISHED, SIM_MAT_FIRE, x, y, life);
            return;
        }
        c.aux = static_cast<uint8_t>(life - 1);
        ++last_stats.changed_cells;
        touch(x, y);
        // 上升：优先正上方，其次左上/右上
        if (empty_at(x, y - 1)) {
            move_to(x, y, x, y - 1);
            return;
        }
        const int32_t dir = (cell_random(x, y, kSaltDir) & 1) ? 1 : -1;
        if (empty_at(x + dir, y - 1)) {
            move_to(x, y, x + dir, y - 1);
            return;
        }
        if (empty_at(x - dir, y - 1)) {
            move_to(x, y, x - dir, y - 1);
        }
    }

    // 烟 / 毒烟 / 蒸汽：轻盈上升+横向漂移；蒸汽到期按 25% 凝结回水。
    inline void process_rising_gas(int32_t x, int32_t y, uint8_t mat) {
        Cell& c = cell_at(x, y);
        const uint8_t life = c.aux;
        if (life <= 1) {
            if (mat == SIM_MAT_STEAM && rand01(x, y, kSaltReact) < kSteamCondenseChance) {
                set_cell_raw(x, y, SIM_MAT_WATER, 0);
            } else {
                set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
            }
            return;
        }
        c.aux = static_cast<uint8_t>(life - 1);
        ++last_stats.changed_cells;
        touch(x, y);
        const uint64_t r = tick_random(x, y, kSaltGasDrift);
        const int32_t dir = (r & 1u) ? 1 : -1;
        if ((r & 3u) != 0u) {
            if (empty_at(x, y - 1)) {
                move_to(x, y, x, y - 1);
                return;
            }
            if (empty_at(x + dir, y - 1)) {
                move_to(x, y, x + dir, y - 1);
                return;
            }
            if (empty_at(x - dir, y - 1)) {
                move_to(x, y, x - dir, y - 1);
                return;
            }
        }
        if (empty_at(x + dir, y)) {
            move_to(x, y, x + dir, y);
        }
    }

    // 阴气：缓慢漂浮；触糯米被净化（r-rice-purify）；aux=0 常驻，aux>0 定时消散。
    inline void process_yin_qi(int32_t x, int32_t y) {
        const int32_t ox[4] = {x - 1, x + 1, x, x};
        const int32_t oy[4] = {y, y, y - 1, y + 1};
        for (int k = 0; k < 4; ++k) {
            const int32_t nx = ox[k], ny = oy[k];
            if (!in_active(nx, ny) || !chunk_loaded_at(nx, ny)) continue;
            if (cell_at(nx, ny).mat == SIM_MAT_GLUTINOUS_RICE) {
                set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
                push_event(SIM_EVENT_REACTION, SIM_MAT_GLUTINOUS_RICE, x, y,
                           SIM_REACT_RICE_PURIFY);
                return;
            }
        }
        Cell& c = cell_at(x, y);
        if (c.aux > 0) {
            if (c.aux <= 1) {
                set_cell_raw(x, y, SIM_MAT_EMPTY, 0);
                return;
            }
            --c.aux;
            ++last_stats.changed_cells;
            touch(x, y);
        }
        const uint64_t r = tick_random(x, y, kSaltGasDrift);
        if ((r & 3u) != 0u) return; // 缓慢诡异漂浮
        const int32_t dir = (r & 4u) ? 1 : -1;
        if ((r & 8u) && empty_at(x, y - 1)) {
            move_to(x, y, x, y - 1);
        } else if (empty_at(x + dir, y)) {
            move_to(x, y, x + dir, y);
        }
    }

    inline void process_cell(int32_t x, int32_t y, Cell& c) {
        const uint8_t m = c.mat;
        if (m == SIM_MAT_EMPTY) return;
        if (c.stamp == static_cast<uint8_t>(tick)) return;
        switch (mat_state[m]) {
            case SIM_STATE_POWDER:
                process_powder(x, y, m);
                return;
            case SIM_STATE_LIQUID:
                process_liquid(x, y, m);
                return;
            case SIM_STATE_GAS:
                if (m == SIM_MAT_FIRE) {
                    process_fire(x, y);
                } else if (m == SIM_MAT_YIN_QI) {
                    process_yin_qi(x, y);
                } else {
                    process_rising_gas(x, y, m);
                }
                return;
            case SIM_STATE_STATIC:
                if (c.aux > 0 && mat_burn_time[m] > 0) {
                    process_burning_fuel(x, y, c);
                }
                return;
            default:
                return;
        }
    }

    void fill_param_tables() {
        for (uint16_t i = 0; i < SIM_MAT_COUNT_; ++i) {
            const simcore::MatDef* d = materials.find(i);
            mat_state[i] = d ? d->state : static_cast<uint8_t>(SIM_STATE_EMPTY);
            mat_density[i] = d ? d->density : 1.0f;
            mat_flammable[i] = d ? d->flammable : 0;
            mat_spread[i] = d ? d->spread : 1;
            mat_life_min[i] = d ? d->fire_life_min : 40;
            mat_life_max[i] = d ? d->fire_life_max : 110;
            mat_ignite[i] = d ? d->ignite_chance : 0.0f;
            mat_ignition_temp[i] = d ? d->ignition_temp : 0.0f;
            mat_burn_time[i] = d ? d->burn_time : 0;
            mat_burn_product[i] = d ? d->burn_product : static_cast<uint16_t>(SIM_MAT_EMPTY);
        }
    }

    void step() {
        ++tick;
        tick_black_powder_blasts = 0;
        // 上一 tick 标记的 chunk 就是本 tick 要处理的集合
        awake_cur.swap(awake_next);
        awake_next.clear();
        std::fill(next_mark.begin(), next_mark.end(), static_cast<uint8_t>(0));

        last_stats.tick = tick;
        last_stats.awake_chunks = 0;
        last_stats.active_cells = 0;
        last_stats.changed_cells = 0;
        last_stats.events = 0;
        tick_events = 0;

        if (ax1 <= ax0 || ay1 <= ay0) {
            awake_cur.clear();
            return;
        }
        const uint8_t t8 = static_cast<uint8_t>(tick);
        const bool left_to_right = (tick & 1ULL) == 0;
        // 自底向上排序活跃 chunk，避免跨 64 格边界下落时产生水平条纹缝隙。
        std::sort(awake_cur.begin(), awake_cur.end(), std::greater<uint32_t>());

        for (const uint32_t ci : awake_cur) {
            Chunk& ch = chunks[ci];
            if (!ch.loaded) continue;
            const int32_t cbase_x = static_cast<int32_t>(ci % chunks_x) << 6;
            const int32_t cbase_y = static_cast<int32_t>(ci / chunks_x) << 6;
            const int32_t x0 = std::max(cbase_x, ax0);
            const int32_t x1 = std::min(cbase_x + kChunk, ax1);
            const int32_t y0 = std::max(cbase_y, ay0);
            const int32_t y1 = std::min(cbase_y + kChunk, ay1);
            if (x0 >= x1 || y0 >= y1) continue;
            ++last_stats.awake_chunks;
            last_stats.active_cells +=
                static_cast<uint32_t>((x1 - x0) * (y1 - y0));
            Cell* cells = ch.cells.data();
            for (int32_t y = y1 - 1; y >= y0; --y) {
                Cell* row = cells + ((y - cbase_y) << 6) - cbase_x;
                if (left_to_right) {
                    for (int32_t x = x0; x < x1; ++x) {
                        Cell& c = row[x];
                        if (c.mat == SIM_MAT_EMPTY || c.stamp == t8) continue;
                        process_cell(x, y, c);
                    }
                } else {
                    for (int32_t x = x1 - 1; x >= x0; --x) {
                        Cell& c = row[x];
                        if (c.mat == SIM_MAT_EMPTY || c.stamp == t8) continue;
                        process_cell(x, y, c);
                    }
                }
            }
        }
        awake_cur.clear();
        last_stats.events = tick_events;
    }

    void wake_rect_impl(sim_rect r) {
        int32_t x0 = std::max<int32_t>(r.x, 0);
        int32_t y0 = std::max<int32_t>(r.y, 0);
        int64_t x1 = static_cast<int64_t>(r.x) + r.w;
        int64_t y1 = static_cast<int64_t>(r.y) + r.h;
        x1 = std::min<int64_t>(x1, width);
        y1 = std::min<int64_t>(y1, height);
        if (x1 <= x0 || y1 <= y0) return;
        const int32_t cx0 = x0 >> 6;
        const int32_t cx1 = (static_cast<int32_t>(x1) - 1) >> 6;
        const int32_t cy0 = y0 >> 6;
        const int32_t cy1 = (static_cast<int32_t>(y1) - 1) >> 6;
        for (int32_t cy = cy0; cy <= cy1; ++cy) {
            for (int32_t cx = cx0; cx <= cx1; ++cx) {
                wake_chunk(static_cast<uint32_t>(cy) * chunks_x + static_cast<uint32_t>(cx));
            }
        }
    }
};

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

extern "C" {

const char* sim_version(void) { return "c-sim/3.0.0"; }

sim_world* sim_world_create(const sim_config* config) {
    if (config == nullptr) return nullptr;
    if (config->width == 0 || config->height == 0) return nullptr;
    if (config->chunk_size != 0 && config->chunk_size != SIM_CHUNK_SIZE) return nullptr;
    const uint64_t total = static_cast<uint64_t>(config->width) * config->height;
    if (total > 16ull * 1024ull * 1024ull) return nullptr; // 16M cells 上限，防误用
    sim_world* w = new (std::nothrow) sim_world();
    if (w == nullptr) return nullptr;
    w->width = config->width;
    w->height = config->height;
    w->seed = config->seed;
    w->tick = 0;
    w->fixed_dt = (config->fixed_dt > 0.0f) ? config->fixed_dt : (1.0f / 60.0f);
    w->chunks_x = (w->width + 63u) / 64u;
    w->chunks_y = (w->height + 63u) / 64u;
    const size_t nchunks = static_cast<size_t>(w->chunks_x) * w->chunks_y;
    w->chunks.resize(nchunks);
    Cell empty_cell{};
    empty_cell.mat = SIM_MAT_EMPTY;
    empty_cell.aux = 0;
    empty_cell.stamp = 0xFF;
    empty_cell.pad = 0;
    for (size_t i = 0; i < nchunks; ++i) {
        w->chunks[i].cells.assign(kChunkCells, empty_cell);
        w->chunks[i].loaded = true;
    }
    w->awake_next.reserve(nchunks);
    w->awake_cur.reserve(nchunks);
    w->next_mark.assign(nchunks, 0);
    w->events.resize(kEventCap);
    w->materials.load(config->materials_json_path);
    w->fill_param_tables();
    // 默认活动区 = 整个世界
    w->ax0 = 0;
    w->ay0 = 0;
    w->ax1 = static_cast<int32_t>(w->width);
    w->ay1 = static_cast<int32_t>(w->height);
    // 初始全部 chunk 进入唤醒队列（step 只处理与活动区相交的）
    for (size_t i = 0; i < nchunks; ++i) {
        w->next_mark[i] = 1;
        w->awake_next.push_back(static_cast<uint32_t>(i));
    }
    return w;
}

void sim_world_destroy(sim_world* world) { delete world; }

uint32_t sim_world_width(const sim_world* w) { return w ? w->width : 0; }
uint32_t sim_world_height(const sim_world* w) { return w ? w->height : 0; }
uint64_t sim_world_seed(const sim_world* w) { return w ? w->seed : 0; }
uint64_t sim_world_tick(const sim_world* w) { return w ? w->tick : 0; }

const char* sim_world_materials_source(const sim_world* w) {
    return w ? w->materials.source().c_str() : "builtin";
}

uint32_t sim_world_chunks_x(const sim_world* w) { return w ? w->chunks_x : 0; }
uint32_t sim_world_chunks_y(const sim_world* w) { return w ? w->chunks_y : 0; }

int sim_world_load_chunk(sim_world* w, uint32_t cx, uint32_t cy) {
    if (w == nullptr || cx >= w->chunks_x || cy >= w->chunks_y) return -1;
    Chunk& ch = w->chunks[static_cast<size_t>(cy) * w->chunks_x + cx];
    if (ch.loaded) return -1;
    Cell empty_cell{};
    empty_cell.mat = SIM_MAT_EMPTY;
    empty_cell.stamp = 0xFF;
    ch.cells.assign(kChunkCells, empty_cell);
    ch.loaded = true;
    w->wake_chunk(static_cast<uint32_t>(cy) * w->chunks_x + cx);
    w->mark_dirty_rect(static_cast<int32_t>(cx) * 64, static_cast<int32_t>(cy) * 64, 64, 64);
    return 0;
}

int sim_world_unload_chunk(sim_world* w, uint32_t cx, uint32_t cy) {
    if (w == nullptr || cx >= w->chunks_x || cy >= w->chunks_y) return -1;
    Chunk& ch = w->chunks[static_cast<size_t>(cy) * w->chunks_x + cx];
    if (!ch.loaded) return -1;
    ch.cells.clear();
    ch.loaded = false;
    w->mark_dirty_rect(static_cast<int32_t>(cx) * 64, static_cast<int32_t>(cy) * 64, 64, 64);
    return 0;
}

int sim_world_chunk_loaded(const sim_world* w, uint32_t cx, uint32_t cy) {
    if (w == nullptr || cx >= w->chunks_x || cy >= w->chunks_y) return 0;
    return w->chunks[static_cast<size_t>(cy) * w->chunks_x + cx].loaded ? 1 : 0;
}

void sim_world_set_active_rect(sim_world* w, sim_rect rect) {
    if (w == nullptr) return;
    int32_t x0 = std::max<int32_t>(rect.x, 0);
    int32_t y0 = std::max<int32_t>(rect.y, 0);
    int64_t x1 = static_cast<int64_t>(rect.x) + std::max<int32_t>(rect.w, 0);
    int64_t y1 = static_cast<int64_t>(rect.y) + std::max<int32_t>(rect.h, 0);
    x1 = std::min<int64_t>(x1, w->width);
    y1 = std::min<int64_t>(y1, w->height);
    w->ax0 = x0;
    w->ay0 = y0;
    w->ax1 = (x1 > x0) ? static_cast<int32_t>(x1) : x0;
    w->ay1 = (y1 > y0) ? static_cast<int32_t>(y1) : y0;
    if (w->ax1 > w->ax0 && w->ay1 > w->ay0) {
        sim_rect r{w->ax0, w->ay0, w->ax1 - w->ax0, w->ay1 - w->ay0};
        w->wake_rect_impl(r);
    }
}

sim_rect sim_world_get_active_rect(const sim_world* w) {
    if (w == nullptr) return sim_rect{0, 0, 0, 0};
    return sim_rect{w->ax0, w->ay0, w->ax1 - w->ax0, w->ay1 - w->ay0};
}

void sim_world_wake_rect(sim_world* w, sim_rect rect) {
    if (w == nullptr) return;
    w->wake_rect_impl(rect);
}

void sim_world_step(sim_world* w) {
    if (w != nullptr) w->step();
}

void sim_world_last_tick_stats(const sim_world* w, sim_tick_stats* out) {
    if (w == nullptr || out == nullptr) return;
    *out = w->last_stats;
}

sim_cell sim_world_get_cell(const sim_world* w, int32_t x, int32_t y) {
    sim_cell out{};
    if (w == nullptr) return out;
    if (x < 0 || y < 0 || x >= static_cast<int32_t>(w->width) ||
        y >= static_cast<int32_t>(w->height)) {
        return out;
    }
    const uint32_t ci = w->chunk_index_xy(x, y);
    if (!w->chunks[ci].loaded) return out;
    const Cell& c = w->chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                       (static_cast<uint32_t>(x) & 63u)];
    out.material = c.mat;
    out.state = w->mat_state[c.mat];
    out.aux = c.aux;
    return out;
}

int sim_world_set_cell(sim_world* w, int32_t x, int32_t y, uint16_t material) {
    if (w == nullptr) return -1;
    if (x < 0 || y < 0 || x >= static_cast<int32_t>(w->width) ||
        y >= static_cast<int32_t>(w->height)) {
        return -1;
    }
    if (material >= SIM_MAT_COUNT_) return -1;
    const uint32_t ci = w->chunk_index_xy(x, y);
    if (!w->chunks[ci].loaded) return -1;
    uint8_t aux = 0;
    if (material == SIM_MAT_FIRE || material == SIM_MAT_SMOKE ||
        material == SIM_MAT_TOXIC_SMOKE || material == SIM_MAT_STEAM) {
        aux = w->gas_initial_life(x, y, material);
    }
    w->set_cell_raw(x, y, static_cast<uint8_t>(material), aux);
    return 0;
}

int sim_world_copy_rect_materials(const sim_world* w, sim_rect rect, uint16_t* out) {
    if (w == nullptr || out == nullptr) return -1;
    if (rect.w <= 0 || rect.h <= 0) return -1;
    if (rect.x < 0 || rect.y < 0 ||
        static_cast<int64_t>(rect.x) + rect.w > w->width ||
        static_cast<int64_t>(rect.y) + rect.h > w->height) {
        return -1;
    }
    uint16_t* dst = out;
    for (int32_t y = rect.y; y < rect.y + rect.h; ++y) {
        for (int32_t x = rect.x; x < rect.x + rect.w; ++x) {
            const uint32_t ci = w->chunk_index_xy(x, y);
            if (!w->chunks[ci].loaded) {
                *dst++ = SIM_MAT_EMPTY;
            } else {
                *dst++ = w->chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                              (static_cast<uint32_t>(x) & 63u)]
                             .mat;
            }
        }
    }
    return 0;
}

uint32_t sim_world_dig(sim_world* w, int32_t cx, int32_t cy, uint32_t radius) {
    if (w == nullptr) return 0;
    if (radius > 256) radius = 256;
    const int32_t r = static_cast<int32_t>(radius);
    const int64_t r2 = static_cast<int64_t>(r) * r;
    uint32_t removed = 0;
    for (int32_t dy = -r; dy <= r; ++dy) {
        for (int32_t dx = -r; dx <= r; ++dx) {
            if (static_cast<int64_t>(dx) * dx + static_cast<int64_t>(dy) * dy > r2) continue;
            const int32_t x = cx + dx;
            const int32_t y = cy + dy;
            if (x < 0 || y < 0 || x >= static_cast<int32_t>(w->width) ||
                y >= static_cast<int32_t>(w->height)) {
                continue;
            }
            const uint32_t ci = w->chunk_index_xy(x, y);
            if (!w->chunks[ci].loaded) continue;
            const Cell& c = w->chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                                 (static_cast<uint32_t>(x) & 63u)];
            const uint8_t st = w->mat_state[c.mat];
            if (st != SIM_STATE_STATIC && st != SIM_STATE_POWDER) continue;
            const uint8_t dug_mat = c.mat;
            ++removed;
            // 约 1/3 的实心格变成沙（碎屑），其余变空。
            const bool debris = (w->cell_random(x, y, kSaltDebris) & 0xFFu) < 85u;
            w->set_cell_raw(x, y, debris ? SIM_MAT_SAND : SIM_MAT_EMPTY, 0);
            w->push_event(SIM_EVENT_DIG, dug_mat, x, y, 0);
        }
    }
    if (removed > 0) {
        // 挖掉支撑后，周围物质需要重新沉降：唤醒圆形外扩一格的范围。
        sim_rect rw{cx - r - 1, cy - r - 1, 2 * r + 3, 2 * r + 3};
        w->wake_rect_impl(rw);
    }
    return removed;
}

sim_rect sim_world_dirty_rect(sim_world* w, int clear) {
    sim_rect out{0, 0, 0, 0};
    if (w == nullptr || !w->dirty_valid) return out;
    out.x = w->dminx;
    out.y = w->dminy;
    out.w = w->dmaxx - w->dminx + 1;
    out.h = w->dmaxy - w->dminy + 1;
    if (clear) {
        w->dirty_valid = false;
    }
    return out;
}

int sim_world_render_rgba8(const sim_world* w, sim_rect rect, uint8_t* rgba,
                           size_t rgba_bytes) {
    if (w == nullptr || rgba == nullptr) return -1;
    if (rect.w <= 0 || rect.h <= 0) return -1;
    if (rect.x < 0 || rect.y < 0 ||
        static_cast<int64_t>(rect.x) + rect.w > w->width ||
        static_cast<int64_t>(rect.y) + rect.h > w->height) {
        return -1;
    }
    const size_t need = static_cast<size_t>(rect.w) * static_cast<size_t>(rect.h) * 4u;
    if (rgba_bytes < need) return -1;
    const uint8_t empty_r = 12, empty_g = 12, empty_b = 16;
    uint8_t* p = rgba;
    for (int32_t y = rect.y; y < rect.y + rect.h; ++y) {
        for (int32_t x = rect.x; x < rect.x + rect.w; ++x) {
            const uint32_t ci = w->chunk_index_xy(x, y);
            uint8_t mat = SIM_MAT_EMPTY;
            uint8_t aux = 0;
            if (w->chunks[ci].loaded) {
                const Cell& c = w->chunks[ci].cells[((static_cast<uint32_t>(y) & 63u) << 6) |
                                                     (static_cast<uint32_t>(x) & 63u)];
                mat = c.mat;
                aux = c.aux;
            }
            uint32_t col = 0;
            if (mat == SIM_MAT_EMPTY) {
                const uint32_t n = static_cast<uint32_t>(mix64(
                    (static_cast<uint64_t>(static_cast<uint32_t>(x)) << 32) ^
                    static_cast<uint32_t>(y) ^ kSaltRender));
                const uint8_t d = static_cast<uint8_t>((n >> 8) & 3u);
                p[0] = static_cast<uint8_t>(empty_r + d);
                p[1] = static_cast<uint8_t>(empty_g + d);
                p[2] = static_cast<uint8_t>(empty_b + d);
                p[3] = 255;
                p += 4;
                continue;
            }
            const uint32_t n = static_cast<uint32_t>(mix64(
                (static_cast<uint64_t>(static_cast<uint32_t>(x)) << 32) ^
                static_cast<uint32_t>(y) ^ (static_cast<uint64_t>(w->tick) << 17) ^ kSaltRender));
            const simcore::MatDef* d = w->materials.find(mat);
            col = d ? d->color_rgb : 0xFF00FF;
            if (mat == SIM_MAT_FIRE) {
                // 火：按剩余寿命从暗红到亮黄，加轻微闪烁。
                const int32_t lo = w->mat_life_min[SIM_MAT_FIRE];
                const int32_t hi = w->mat_life_max[SIM_MAT_FIRE];
                float t = (hi > lo) ? static_cast<float>(aux) / static_cast<float>(hi) : 0.5f;
                t = std::min(1.0f, std::max(0.0f, t));
                const float flick = 0.85f + 0.15f * static_cast<float>((n >> 10) & 0xFFu) / 255.0f;
                uint8_t r = static_cast<uint8_t>(std::min(255.0f, (150.0f + 100.0f * t) * flick));
                uint8_t g = static_cast<uint8_t>(std::min(255.0f, (30.0f + 170.0f * t) * flick));
                uint8_t b = static_cast<uint8_t>(std::min(255.0f, (10.0f + 40.0f * t) * flick));
                p[0] = r;
                p[1] = g;
                p[2] = b;
                p[3] = 255;
                p += 4;
                continue;
            }
            const int32_t jitter = static_cast<int32_t>((n >> 12) & 15u) - 7;
            int32_t r = static_cast<int32_t>((col >> 16) & 0xFFu) + jitter;
            int32_t g = static_cast<int32_t>((col >> 8) & 0xFFu) + jitter;
            int32_t b = static_cast<int32_t>(col & 0xFFu) + jitter;
            // C-SIM v3：正在燃烧的固体/粉末燃料（aux > 0）叠加橙红余烬闪烁
            if (aux > 0 && w->mat_burn_time[mat] > 0) {
                const float flick = 0.55f + 0.45f * static_cast<float>((n >> 10) & 0xFFu) / 255.0f;
                r = static_cast<int32_t>(r * 0.35f + 255.0f * 0.65f * flick);
                g = static_cast<int32_t>(g * 0.35f + 110.0f * 0.65f * flick);
                b = static_cast<int32_t>(b * 0.35f + 24.0f * 0.65f * flick);
            }
            // 液体表面提亮，便于目测分层
            if (w->mat_state[mat] == SIM_STATE_LIQUID && y > 0) {
                const uint32_t upi =
                    w->chunk_index_xy(x, y - 1);
                uint8_t up = static_cast<uint8_t>(SIM_MAT_EMPTY);
                if (w->chunks[upi].loaded) {
                    up = w->chunks[upi]
                             .cells[((static_cast<uint32_t>(y - 1) & 63u) << 6) |
                                    (static_cast<uint32_t>(x) & 63u)]
                             .mat;
                }
                if (up != mat) {
                    r += 18;
                    g += 18;
                    b += 18;
                }
            }
            p[0] = static_cast<uint8_t>(std::clamp(r, 0, 255));
            p[1] = static_cast<uint8_t>(std::clamp(g, 0, 255));
            p[2] = static_cast<uint8_t>(std::clamp(b, 0, 255));
            p[3] = 255;
            p += 4;
        }
    }
    return 0;
}

uint64_t sim_world_hash(const sim_world* w) {
    if (w == nullptr) return 0;
    uint64_t h = mix64(w->seed ^ 0xC0FFEE123456789ULL);
    h = mix64(h ^ w->tick);
    uint64_t idx = 0;
    for (const Chunk& ch : w->chunks) {
        if (!ch.loaded) {
            h = mix64(h ^ (idx * 0x9E3779B97F4A7C15ULL) ^ 0xDEADBEEFULL);
            ++idx;
            continue;
        }
        for (const Cell& c : ch.cells) {
            const uint64_t v = static_cast<uint64_t>(c.mat) |
                               (static_cast<uint64_t>(c.aux) << 8);
            h = mix64(h ^ v ^ (idx * 0xD6E8FEB86659FD93ULL));
            ++idx;
        }
    }
    return h;
}

uint32_t sim_world_material_count(const sim_world* w) {
    if (w == nullptr) return 0;
    return static_cast<uint32_t>(w->materials.defs().size());
}

int sim_world_material_info(const sim_world* w, uint16_t id, sim_material_info* out) {
    if (w == nullptr || out == nullptr) return -1;
    const simcore::MatDef* d = w->materials.find(id);
    if (d == nullptr) return -1;
    out->id = d->id;
    out->id_str = d->id_str.c_str();
    out->display = d->display.c_str();
    out->state = d->state;
    out->density = d->density;
    out->color_rgb = d->color_rgb;
    out->flammable = d->flammable;
    out->experimental = d->experimental;
    return 0;
}

uint16_t sim_world_material_id_by_str(const sim_world* w, const char* id_str) {
    if (w == nullptr || id_str == nullptr) return std::numeric_limits<uint16_t>::max();
    for (const simcore::MatDef& d : w->materials.defs()) {
        if (d.id_str == id_str) return d.id;
    }
    return std::numeric_limits<uint16_t>::max();
}

float sim_world_material_ignition_temp(const sim_world* w, uint16_t id) {
    if (w == nullptr || id >= SIM_MAT_COUNT_) return 0.0f;
    return w->mat_ignition_temp[id];
}

const char* sim_reaction_id_str(uint16_t reaction_id) {
    switch (reaction_id) {
        case SIM_REACT_BLACK_POWDER:
            return "r-black-powder";
        case SIM_REACT_SULFUR_TOXIC_SMOKE:
            return "r-sulfur-toxic-smoke";
        case SIM_REACT_BAMBOO_BURN:
            return "r-bamboo-burn";
        case SIM_REACT_LIME_STEAM:
            return "r-lime-steam";
        case SIM_REACT_RICE_PURIFY:
            return "r-rice-purify";
        default:
            return "";
    }
}

uint32_t sim_world_apply_heat_burst(sim_world* w, int32_t cx, int32_t cy, uint32_t radius,
                                    float heat_temp) {
    if (w == nullptr || heat_temp <= 0.0f) return 0;
    if (radius > 128u) radius = 128u;
    const int32_t r = static_cast<int32_t>(radius);
    const int64_t r2 = static_cast<int64_t>(r) * r;
    w->tick_black_powder_blasts = 0;
    uint32_t affected = 0;
    for (int32_t dy = -r; dy <= r; ++dy) {
        for (int32_t dx = -r; dx <= r; ++dx) {
            if (static_cast<int64_t>(dx) * dx + static_cast<int64_t>(dy) * dy > r2) continue;
            affected += w->apply_heat_to_cell(cx + dx, cy + dy, heat_temp, true);
        }
    }
    if (affected > 0) {
        w->wake_rect_impl(sim_rect{cx - r - 2, cy - r - 2, 2 * r + 5, 2 * r + 5});
    }
    return affected;
}

uint32_t sim_world_poll_events(sim_world* w, sim_event* out, uint32_t capacity) {
    if (w == nullptr || out == nullptr || capacity == 0) return 0;
    const uint32_t n = std::min(capacity, w->ev_count);
    for (uint32_t i = 0; i < n; ++i) {
        const uint32_t start = (w->ev_head + kEventCap - w->ev_count) % kEventCap;
        out[i] = w->events[(start + i) % kEventCap];
    }
    w->ev_count -= n;
    return n;
}

}  // extern "C"
