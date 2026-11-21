# 战斗与物质特效的实现方式

> 主题：**本作的战斗/物质特效（命中、击杀、8 条民俗反应、火焰与气体）用哪种方式实现——序列帧图集、程序化着色器，还是维持现有的 CPU 自绘**
> 日期：2026-11-21｜状态：**待试验**｜触发：用户提供抖音《像素风游戏特效最高的山，每个特效不是图片而是一段代码》（S1）
> 关联：`docs/01-decision-twist.md` D1 可读优先；`docs/tech/m1-feedback-juice.md`（M1-10 反馈层）；`refs/cards/decisions/visual-production.md`（环境表现层的生产路线，与本卡不同层）

## 当前选择与理由

**维持"程序化"为主：把现有的 CPU 自绘升级为 shader + `GPUParticles2D`；pixelfx 只当"草稿生成器与参考"，不当素材库；序列帧留给不需要运行时变色的长动画（BOSS 出场/过场）。**

理由：

1. **D1 要求特效按语义变色**。同一套火星既要能是火橙、阴紫，也要是水蓝/金/木/土（`feedback_director._type_color()` 已经这么做）。序列帧是烘死的颜色，运行时变色只能整体 `modulate`，无法"火焰内核白、外焰橙、余烬暗红"的分层。
2. **本作是事件驱动**：特效由 C-EVT（`reaction_triggered`/`entity_damaged`…）驱动，参数来自实体与材质。程序化天然接受参数（半径、颜色、方向、强度），序列帧只能选帧。
3. **分辨率极低（1 cell = 4 px）**，手工序列帧在这个尺寸下的信息量优势不明显；而程序化在 4 px 网格上画圆/方/线反而更干净。
4. **S4（方法原作者）明确反对"一发入魂"**：`pixelfx` 的 README 自称"every one a small piece of code"，而方法文说"很多人想让你相信 AI 能一次生成好结果……尤其在像素特效上，不行，得下功夫"。所以引入它的正确姿势是**流程**（草稿 → 渲染 → 挑 → 精修），不是复制资产。

---

## 症状

- M1-10 的反馈层已经能打（火光、火星、爆散、飘字、白闪），但**8 条民俗反应共用同一套"通用环 + 火星"**，只有颜色区分，缺少各自的"签名动作"（例如黑火药应是白闪 + 冲击波 + 落尘，糯米净化应是向内收束的环，水银界应是沿格边蔓延的线）。
- 现有实现是 **GDScript 数组 + `draw_*` 自绘**（`fx_layer.gd`），每帧 CPU 遍历；粒子数量上限数百，形态只有"方点 + 圆环 + 光晕"。

## 现版基线

| 层 | 现状 | 位置 |
|---|---|---|
| 世界空间特效 | CPU 自绘：火花（方块）、冲击环（`draw_arc`）、光晕（`GradientTexture2D`）、飘字（`draw_string`） | `game/scripts/feedback/fx_layer.gd` |
| 屏幕空间 | 白闪 + 边缘红晕（`ColorRect`） | `screen_fx.gd` |
| 一次性提示 | 施法环、喷液线 | `game/scripts/overlay.gd` |
| 事件源 | C-EVT v0.1（22 种事件） | `game/scripts/event_bus.gd` |
| 渲染器 | GL Compatibility，内部 480×270 整数 4× 到 1080p | `game/project.godot` |

## 约束

- **D1 可读优先**：每条特效至少两个表达通道（颜色/形状/声音），已学会的因果不能被遮蔽。
- **M1 范围**：不做像素刚体碎裂、不做水墨后处理。
- **性能**：模拟 6 ms/tick 预算已被占用；渲染侧给特效的增量目标 ≤ 0.5 ms。
- **许可**：`pixelfx` 是 MIT，可商用，但**必须保留版权与许可声明**（需要 `THIRD_PARTY.md`）。
- **技术栈**：pixelfx 是 **JavaScript/Canvas/three.js**，**没有 Godot 移植**；只能"导出序列帧"或"读代码重写"。

---

## 候选比较

### shader-vfx

**做法**：在 Godot 内用 `CanvasItem` fragment shader（命中闪白、溶解、能量环）+ `GPUParticles2D`（火星/尘/烟）重写特效层，参数由 C-EVT 注入。

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 命中/击杀/8 条反应/火焰气体；需要按 `damage_type` 与材质实时变色的场合 |
| 证据与边界 | S3（Dome Keeper 技术拆解，二手转述）：Godot 里用 fragment shader 做深度调色、CanvasItem 软阴影、`GPUParticles2D` + 16×16 纹理 + 寿命 <1 s + burst 避免尖峰。S1/S2 证明"代码生成的像素特效"在美术上可以到商业级，但**那是 JS 生态的产物，不是 Godot 的实现证据** |
| 本作映射 | **部分已有**：事件总线、取色、光晕贴图。**缺失**：shader、GPU 粒子、形态库。**待核实**：GL Compatibility 下 `GPUParticles2D` 的实测开销 |
| 代价与依赖 | 每条签名特效 0.5–1.5 人日（AI 起草 + 手调）；无美术依赖；需新增 `data/fx.json` 或常量表 |
| 最小验证 | 见下节 |

### sheet-export

**做法**：用 pixelfx 的导出功能产出序列帧 PNG，导入 Godot 作 `SpriteFrames`，用 `AnimatedSprite2D` 播放；颜色整体 `modulate`。

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 外观固定、时长较长、播放频率低的特效：BOSS 出场、过场、技能预告 |
| 证据与边界 | S2（上游 README）：244 个特效，MIT，"export sprite sheets for any engine"。这条是**可复现的能力声明**（导出功能在仓库里），但我**没有实际跑过导出**，图集尺寸/帧率/透明边缘未核实。视频 S1 转写两次失败（临时文件缺失），未取到画面，主张以原仓库为准 |
| 本作映射 | **缺失**的是"高质量长动画"；**不匹配**的是运行时变色与事件参数化（命中点方向、强度、材质） |
| 代价与依赖 | 每条 0.2 人日（导出 + 导入 + 调帧率）；风险：4 px 网格下缩放的模糊/抖动，需要逐条检查像素对齐；MIT 声明 |
| 最小验证 | 导出 1 条（如 "big explosion"）在 Godot 里按 4× 放大播放，检查像素对齐与变色效果 |

### cpu-draw-baseline

**做法（基线）**：维持 `fx_layer.gd` 的数组自绘，增加形态（线、锥、多边形）。

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 已经在跑，零风险；粒子数 ≤ 400 时开销可忽略 |
| 证据与边界 | 本仓库实机 smoke + 截图为证（`--t4b-fx-shot`）；上限未压测 |
| 本作映射 | 现状 |
| 代价与依赖 | 扩展成本低（每条 0.2 人日），但形态与混合模式受限（无加法混合、无软边、无 GPU 并行） |
| 最小验证 | 压测：同屏 400 粒子 + 8 条反应同时触发时的帧时间 |

---

## 条件化优先顺序

1. **先做 `shader-vfx` 的一个切片**（推荐）：只重写"命中/击杀"两条，与原 CPU 版做 A/B——因为这两条占屏时间最长、复用最多。
2. **8 条反应的"签名形态"排在第二位**，但**必须一条一条做**（D1 的核心卖点是"每条反应用两种通道说清"），不要一次铺开。
3. **`sheet-export` 只在 BOSS/过场需要时启用**；启用前先做像素对齐检查。
4. **`cpu-draw-baseline` 保持为回退路径**：`fx_impl = "cpu"\|"shader"` 开关，随时能退回。

## 最小验证（一周内）

| 项 | 内容 |
|---|---|
| 场景 | 固定 seed `20261121` 的矿井入口安全区；用脚本连续触发 3 次命中 + 1 次击杀 |
| 基线 | 当前 CPU 自绘版 |
| 只改的变量 | 命中/击杀改 shader + `GPUParticles2D`，其余不动 |
| 观察项 | ① 1080p GL Compatibility 帧时间增量；② 录屏 A/B 盲选（3 次 ≥2）；③ 反应辨识度核对表不打折 |
| 通过标准 | 增量 ≤ 0.5 ms + 盲选 ≥2/3 + 辨识无回退 |
| 回退条件 | `fx_impl` 切回 `cpu` |
| 附：pixelfx 流程试跑 | 用其 skill 产出 5 个"冲击/命中"草稿，记录轮次与耗时（验证"代码即黏土"在本作是否真的省时间） |

## 待证项

- `GPUParticles2D` 在 GL Compatibility 下的实测开销与混合模式限制。
- pixelfx 导出图集在 4 px/cell 尺度下的像素对齐与褪色表现。
- "草稿 → 精修"流程在本作的实际返工轮次（S4 只说方法有效，没给工时）。
- S1 视频的画面未取到（转写两次失败），其"最高の山"属营销表述，不作为证据。

---

## 来源表

| 编号 | 作品 / 作者 | 平台 | 原链接 | 日期 / 版本 | 实际读取范围 | 成熟度 |
|---|---|---|---|---|---|---|
| S1 | 《像素风游戏特效最高的山，每个特效不是图片而是一段代码，连带 Skill 一起开源》/ 阿甘探AI | 抖音 | https://v.douyin.com/RRBAPzj9JBw/ | 2026-11-05，29 s，5916 赞 / 7082 收藏 | **仅标题与标签**：语音转写两次失败（临时媒体文件缺失），未抽帧 | 线索（待核实） |
| S2 | pixelfx / patch-gg | GitHub | https://github.com/patch-gg/pixelfx | 8587 ★，MIT，JavaScript | README 正文：244 个特效、每特效一段代码、可导出序列帧给任意引擎、"acting" 12 连招、Claude Code skill、方法来源 Hugo Duprez | 可复现演示（仓库级） |
| S3 | pixelfx 中文版 / bayshier | GitHub | https://github.com/bayshier/pixelfx-zh | 109 ★，MIT，2026-11-21 更新 | README 正文（分类表：moves/fire/explosions/water/ice/lightning/sci-fi/melee/impacts/projectiles…） | 二手镜像（同源） |
| S4 | How to make (good) pixel art effects with Claude / Hugo Duprez | Sprite Fusion 博客 | https://www.spritefusion.com/blog/how-to-make-good-pixel-art-effects-with-claude | 2026-10-28 | 正文前三节：code is clay（草稿 5–10 版）、trust your eyes、references；明确反对"一发入魂" | 作者原文 |
| S5 | Dome Keeper: 在 Godot 中实现氛围像素艺术的技术要点 | Foro3D（自动翻译） | https://foro3d.com/en/2026/mayo/dome-keeper-claves-tecnicas-de-su-pixel-art-atmosferico-en-godot.html | 2026-05-30 | 全文：fragment shader 调色、CanvasItem 软阴影、`GPUParticles2D`/16×16/寿命<1s/burst | 已发行实装（二手转述） |
| S6 | 本仓库现状 | 本地 | `game/scripts/feedback/fx_layer.gd`、`project.godot` | 2026-11-21 | 代码 + `--t4b-smoke` / `--t4b-fx-shot` 实测 | 本作实装 |
