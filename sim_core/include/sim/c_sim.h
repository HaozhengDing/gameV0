/*
 * C-SIM v1 — sim_core 对外契约（C ABI）
 * =====================================
 * 本头文件是 sim_core 与外部（Godot GDExtension / T4 灰盒 / 基准 / 测试）之间
 * 唯一的稳定接口。只依赖 <stdint.h> / <stddef.h>，可被 C 与 C++ 同时包含。
 *
 * 单位与语义（D4 定）：
 *   - 1 cell ≡ 1 世界像素。内部分辨率 480x270 的视口 = 480x270 cells。
 *   - 固定 tick：每次 sim_world_step() 恰好推进 1 tick；默认 fixed_dt = 1/60 s，
 *     即 60 Hz。模拟不读取墙钟时间，步进次数完全由调用方决定 → 可回放、可确定。
 *   - 密度：水 = 1.0（与 data/materials.json 的 conventions 一致）。
 *   - 坐标：cell 坐标，(0,0) 为世界左上角，x 向右、y 向下（与图像一致）。
 *   - 材质参数：世界创建时从 sim_config.materials_json_path 读取
 *     data/materials.json 中的 water / quicksilver / rock（id 见 sim_material）。
 *     sand / oil / fire 是 sim_core 内的「实验物质」，不在 data/ 中（不改 data/）。
 *     读不到 JSON 时回退编译期默认值（材质来源可查 sim_world_materials_source）。
 *
 * 确定性：
 *   - 同一 seed + 同一串 API 调用 = 同一结果（无墙钟、无未初始化内存、无随机线程）。
 *   - 唯一例外：不保证不同编译器/优化级别下逐字节一致（浮点密度比较在 1e-6 量级内
 *     稳定；所有随机性来自整数 hash）。
 *
 * 线程：
 *   - 单线程。所有 sim_world_* 接口都不得从多个线程并发调用同一个 world。
 *   - 不同 world 之间无共享可变状态，可并行。
 *
 * 所有权：
 *   - sim_world_create 返回的指针由调用方用 sim_world_destroy 释放。
 *   - 其余返回的指针（字符串等）归 world 所有，world 销毁后失效。
 *
 * 契约版本：SIM_C_SIM_VERSION。破坏性修改必须递增版本号。
 */
#ifndef SIM_C_SIM_H
#define SIM_C_SIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIM_C_SIM_VERSION 1u
#define SIM_CHUNK_SIZE 64u

/* ------------------------------------------------------------------ */
/* 物质                                                                */
/* ------------------------------------------------------------------ */

/* 物质状态分类。决定运动规则，不决定具体形状。 */
typedef enum sim_state {
    SIM_STATE_EMPTY = 0,  /* 空（非材质） */
    SIM_STATE_POWDER = 1, /* 粉末：下落、堆角、可被更重液体沉入 */
    SIM_STATE_LIQUID = 2, /* 液体：下落、按密度分层、横向找平 */
    SIM_STATE_GAS = 3,    /* 气体：上升、可被排开（v1 只有火） */
    SIM_STATE_STATIC = 4  /* 静态固体：不动，可被 dig 挖掉 */
} sim_state;

/* 内置物质 id。v1 固定 7 个；未来扩展必须追加，不能改已有数值。 */
typedef enum sim_material {
    SIM_MAT_EMPTY = 0,
    SIM_MAT_ROCK = 1,        /* 岩（data/materials.json: rock） */
    SIM_MAT_SAND = 2,        /* 沙（sim 实验物质） */
    SIM_MAT_WATER = 3,       /* 水（data/materials.json: water） */
    SIM_MAT_OIL = 4,         /* 油（sim 实验物质，可燃） */
    SIM_MAT_QUICKSILVER = 5, /* 水银（data/materials.json: quicksilver，密度 13.6） */
    SIM_MAT_FIRE = 6,        /* 火（sim 实验物质，带寿命的气体） */
    SIM_MAT_COUNT_ = 7       /* 有效 id 上界（不含） */
} sim_material;

/* 单个 cell 的只读快照。 */
typedef struct sim_cell {
    uint16_t material; /* sim_material */
    uint8_t state;     /* sim_state，随 material 固定，便于渲染侧免查表 */
    uint8_t aux;       /* 材质附加量：火 = 剩余寿命（tick，1..255）；其它 = 0 */
} sim_cell;

/* 物质静态参数（只读，来自 data/materials.json 或编译期默认值）。 */
typedef struct sim_material_info {
    uint16_t id;         /* sim_material */
    const char* id_str;  /* 稳定字符串 id，如 "water"、"sand" */
    const char* display; /* UTF-8 短名，如 "水" */
    uint8_t state;       /* sim_state */
    float density;       /* 水 = 1.0 */
    uint32_t color_rgb;  /* 0xRRGGBB，调试渲染用 */
    uint8_t flammable;   /* 1 = 可被火点燃 */
    uint8_t experimental;/* 1 = 定义在 sim_core 内，不在 data/materials.json */
} sim_material_info;

/* ------------------------------------------------------------------ */
/* 世界                                                                */
/* ------------------------------------------------------------------ */

typedef struct sim_world sim_world; /* 不透明句柄 */

/* 世界创建参数。宽高必须 > 0；chunk_size 必须为 0 或 64。 */
typedef struct sim_config {
    uint32_t width;  /* 世界宽（cells） */
    uint32_t height; /* 世界高（cells） */
    uint64_t seed;   /* 场景/燃烧等所有随机性的种子 */
    uint32_t chunk_size; /* 0 → SIM_CHUNK_SIZE(64) */
    float fixed_dt;      /* 每 tick 秒数；<=0 → 1/60。v1 仅记录，不参与运动计算 */
    /* 可选：data/materials.json 路径。NULL / 读失败 → 回退编译期默认值。 */
    const char* materials_json_path;
} sim_config;

/* 矩形（cells）。w <= 0 或 h <= 0 表示空矩形。 */
typedef struct sim_rect {
    int32_t x;
    int32_t y;
    int32_t w;
    int32_t h;
} sim_rect;

/* 一次 tick 的统计（调试 / 性能分析用）。 */
typedef struct sim_tick_stats {
    uint64_t tick;         /* 本次 tick 的序号（从 1 开始） */
    uint32_t awake_chunks; /* 被处理的 chunk 数 */
    uint32_t active_cells; /* 被扫描的 cell 数 */
    uint32_t changed_cells;/* 被写过的 cell 数 */
    uint32_t events;       /* 本次 tick 新产生的事件数 */
} sim_tick_stats;

/* 最小事件输出。用于音效 / 粒子 / 玩法回调；不是精确审计日志。 */
typedef enum sim_event_type {
    SIM_EVENT_FIRE_IGNITED = 1,       /* 有物质被点燃：x,y 为火的位置，material 为被烧掉的物质 */
    SIM_EVENT_FIRE_EXTINGUISHED = 2,  /* 火熄灭 / 被水浇灭：x,y 为原火位置 */
    SIM_EVENT_DIG = 3                 /* 每挖掉一个 cell 一条：x,y 为被挖 cell */
} sim_event_type;

typedef struct sim_event {
    uint16_t type;     /* sim_event_type */
    uint16_t material; /* 相关物质 id（可为 0） */
    int32_t x;
    int32_t y;
    uint16_t aux;      /* 保留：火 = 初始寿命 */
    uint16_t pad;
} sim_event;

/* ------------------------------ 生命周期 ------------------------------ */

/* 创建世界。失败返回 NULL。创建后所有 chunk 均为「已载入、内容为空」状态，
 * 活动区默认为整个世界。创建时读材质参数，读不到 JSON 只回退、不算失败。 */
sim_world* sim_world_create(const sim_config* config);

/* 销毁世界。传入 NULL 安全。 */
void sim_world_destroy(sim_world* world);

/* 契约版本字符串（如 "c-sim/1.0.0"）。 */
const char* sim_version(void);

/* ------------------------------ 基本属性 ------------------------------ */

uint32_t sim_world_width(const sim_world* world);
uint32_t sim_world_height(const sim_world* world);
uint64_t sim_world_seed(const sim_world* world);
uint64_t sim_world_tick(const sim_world* world);

/* 材质来源："data/materials.json"（成功读到）/ "builtin"（回退）。 */
const char* sim_world_materials_source(const sim_world* world);

/* ------------------------------ chunk 流式载入 ------------------------------ */

uint32_t sim_world_chunks_x(const sim_world* world);
uint32_t sim_world_chunks_y(const sim_world* world);

/* 载入一个 chunk（坐标越界或已载入返回错误）。载入会把该 chunk 清空。
 * 未载入 chunk 视为不可进入的墙：cell 查询返回空，set 失败，物质不会流入。 */
int sim_world_load_chunk(sim_world* world, uint32_t cx, uint32_t cy);

/* 卸载一个 chunk：释放并清空其内容（不保留数据，v1 不做持久化）。
 * 活动区内正在模拟的物质无法流出到未载入 chunk。 */
int sim_world_unload_chunk(sim_world* world, uint32_t cx, uint32_t cy);
int sim_world_chunk_loaded(const sim_world* world, uint32_t cx, uint32_t cy);

/* ------------------------------ 活动区 ------------------------------ */

/* 设置每 tick 参与模拟的矩形（cells，外层自动裁剪到世界，且对齐无需）。
 * 默认 = 整个世界。活动区边界按「墙」处理：物质不会流出/流入活动区。
 * 主要用途：典型场景只模拟视口附近；以及相机移动时切换活跃区域。 */
void sim_world_set_active_rect(sim_world* world, sim_rect rect);
sim_rect sim_world_get_active_rect(const sim_world* world);

/* 强制唤醒矩形内的 chunk（外部事件用：爆炸、玩家挖到边界、新载入 chunk 等）。
 * 唤醒只影响调度，不改变 cell 内容。 */
void sim_world_wake_rect(sim_world* world, sim_rect rect);

/* ------------------------------ 步进 ------------------------------ */

/* 推进恰好 1 个固定 tick（默认 1/60 s）。不读墙钟。
 * 只处理活动区内、且上一 tick 有变化的 chunk（休眠优化）。 */
void sim_world_step(sim_world* world);

/* 取上一 tick 的统计。 */
void sim_world_last_tick_stats(const sim_world* world, sim_tick_stats* out);

/* ------------------------------ cell 读写 ------------------------------ */

/* 读取 cell。越界 / 未载入 chunk → 返回空 cell（material = SIM_MAT_EMPTY）。 */
sim_cell sim_world_get_cell(const sim_world* world, int32_t x, int32_t y);

/* 写入 cell（会唤醒所在 chunk 并计入下一 tick 的脏矩形）。
 * 返回 0 成功；-1 参数非法（越界 / 材质 id 非法 / chunk 未载入）。 */
int sim_world_set_cell(sim_world* world, int32_t x, int32_t y, uint16_t material);

/* 批量读取矩形内的物质 id（只填 material，不带 aux）。用于渲染/调试。
 * out 长度必须 >= rect.w * rect.h，行优先。返回 0 成功。 */
int sim_world_copy_rect_materials(const sim_world* world, sim_rect rect, uint16_t* out);

/* ------------------------------ 挖掘 ------------------------------ */

/* 以 (x, y) 为圆心挖一个圆（半径 radius cells，含边界附近为整数格近似）。
 * 只移除 POWDER / STATIC；液体、气体原地保留（会流入空腔）。
 * 被挖掉的实心格有约 1/3 变成沙（碎屑），其余变空。
 * 返回被挖掉的 cell 数（不含碎屑）。 */
uint32_t sim_world_dig(sim_world* world, int32_t x, int32_t y, uint32_t radius);

/* ------------------------------ 脏矩形 ------------------------------ */

/* 自上次 clear=1 查询以来所有被写过的 cell 的包围盒。
 * 无变化 → w=0/h=0。clear=1 时同时重置。渲染侧用它决定上传区域。 */
sim_rect sim_world_dirty_rect(sim_world* world, int clear);

/* ------------------------------ 渲染（可选） ------------------------------ */

/* 把矩形区域渲染成 RGBA8（行优先，每像素 4 字节 R,G,B,A，A=255）。
 * 颜色来自材质表 + 按坐标 hash 的明暗抖动；火按剩余寿命变色。
 * 空 cell 为近黑色。用于基准 PNG 与调试视图；不是正式美术管线。
 * 返回 0 成功；-1 参数非法（rect 越界 / rgba_bytes 不足）。 */
int sim_world_render_rgba8(const sim_world* world, sim_rect rect, uint8_t* rgba,
                           size_t rgba_bytes);

/* ------------------------------ 确定性哈希 ------------------------------ */

/* 对世界全部已载入 cell（material + aux）及 seed/tick 做稳定哈希。
 * 用于确定性测试：同 seed 两次运行必须相同。 */
uint64_t sim_world_hash(const sim_world* world);

/* ------------------------------ 材质表 ------------------------------ */

uint32_t sim_world_material_count(const sim_world* world);

/* 查询材质参数。id 合法返回 0 并写 *out；否则 -1。 */
int sim_world_material_info(const sim_world* world, uint16_t id, sim_material_info* out);

/* 按字符串 id 查材质 id（如 "water"）；找不到返回 UINT16_MAX。 */
uint16_t sim_world_material_id_by_str(const sim_world* world, const char* id_str);

/* ------------------------------ 事件 ------------------------------ */

/* 取出事件（copy 到 out，最多 capacity 条），返回实际条数。
 * 事件缓冲有上限（未取走的事件可能被丢弃）；每 tick 结束时由调用方主动 poll。 */
uint32_t sim_world_poll_events(sim_world* world, sim_event* out, uint32_t capacity);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SIM_C_SIM_H */
