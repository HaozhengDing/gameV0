# 2026-11-21-17 特效实现方式：把"每特效一段代码"的视频拆成方案卡

- **日期**：2026-11-21
- **类型**：调研 + 建议（未改代码）
- **篇幅**：详细（新增一张决策卡 + 3 个候选 + 一周最小验证）
- **触发**：用户提供抖音《像素风游戏特效最高的山，每个特效不是图片而是一段代码，连带 Skill 一起开源》（阿甘探AI，2026-11-05，29 s）
- **方法**：沿用 `game-decision-research` skill；卡按 `refs/cards/decisions/README.md` 规范写。

---

## 1. 采证过程（含失败记录）

| 尝试 | 结果 |
|---|---|
| 抖音转写（第 1 次） | **失败**：临时媒体文件不存在 |
| 抖音转写（第 2 次，`keep_media`） | **失败**：同上；两次都只拿到标题与标签，**未取到画面** |
| 反查原项目 | **成功**：视频讲的正是开源项目 [**pixelfx**](https://github.com/patch-gg/pixelfx)（8587 ★，MIT，JavaScript），中文版 [pixelfx-zh](https://github.com/bayshier/pixelfx-zh)（109 ★） |
| 方法原文 | **成功**：pixelfx 自述方法来自 Hugo Duprez《How to make (good) pixel art effects with Claude》（Sprite Fusion 博客，2026-10-28） |

所以本卡的证据以**原仓库与原作者博客**为主，视频只作线索（其"最高の山"属营销表述）。

## 2. 结论

**维持程序化为主，把 `fx_layer` 的 CPU 自绘升级为 shader + `GPUParticles2D`；pixelfx 当"草稿生成器与参考"，不当素材库；序列帧只留给不需要运行时变色的长动画。**

四条理由：

1. **D1 要求按语义变色**：同一套火星要能是火橙/阴紫/水蓝/金/木/土（`feedback_director._type_color()` 已如此）。序列帧是烘死的颜色，整体 `modulate` 做不出"内核白、外焰橙、余烬暗红"的分层。
2. **事件驱动**：特效由 C-EVT 注入半径、方向、强度、材质，程序化天然接受参数；序列帧只能选帧。
3. **1 cell = 4 px**：这个尺寸下手工序列帧的信息量优势不明显，程序化反而更能做"像素级干净"的形态。
4. **原作者自己反对"一发入魂"**：S4 原文——"很多人想让你相信 AI 能一次生成好结果……尤其在像素特效上，不行，得下功夫"。所以引入它的正确姿势是**流程**（草稿 → 渲染 → 挑 → 精修），不是复制资产。

卡：[refs/cards/decisions/vfx-implementation.md](../../refs/cards/decisions/vfx-implementation.md)

## 3. 三个候选（详见卡片）

| 候选 | 一句话 | 建议 |
|---|---|---|
| `shader-vfx` | Godot 内用 CanvasItem shader + `GPUParticles2D` 自写 | **先做"命中/击杀"两条切片** |
| `sheet-export` | pixelfx 导出序列帧 → `SpriteFrames` | 只给 BOSS 出场/过场等固定外观的长动画 |
| `cpu-draw-baseline` | 现有 `fx_layer` 数组自绘，扩形态 | 保留为回退路径（`fx_impl` 开关） |

关键事实澄清：**pixelfx 是 JS/Canvas/three.js，没有 Godot 移植**——要么导出图集，要么读代码重写。这一点决定了它不可能"直接拿来用"。

## 4. 最小验证（一周内）

固定 seed `20261121` 入口安全区，脚本连续触发 3 次命中 + 1 次击杀 → 只把这两条改成 shader + GPU 粒子 → 测 1080p GL Compatibility 帧时间增量 ≤ 0.5 ms、录屏 A/B 盲选 ≥2/3、8 条反应辨识度不打折；回退 `fx_impl = cpu`。
附：用 pixelfx 的 skill 产出 5 个"冲击/命中"草稿，记录轮次与耗时，验证"代码即黏土"在本作是否真的省时间。

## 5. 若采纳为任务（输入 / 输出 / 依赖）

- **输入**：本卡；`fx_layer.gd` 现有形态；`feedback_director` 的取色表；`docs/tech/m1-feedback-juice.md` §3 落地表。
- **输出**：`game/scripts/feedback/fx_shader/`（`hit.gdshader`、`kill.gdshader`、粒子场景）、`fx_impl` 开关、A/B 录屏与帧时间记录（写回卡片"已试验"段）。
- **依赖类型**：**软** 依赖 M1-10（取色与事件已就位）；**硬** 无；**决策** 依赖盲选结果。
- **许可**：若导入 pixelfx 导出图集，新增 `THIRD_PARTY.md` 记录 MIT 版权声明。

## 6. 待证项

1. `GPUParticles2D` 在 GL Compatibility 下的实测开销与混合模式限制。
2. pixelfx 导出图集在 4 px/cell 尺度的像素对齐（未实际跑导出）。
3. "草稿 → 精修"流程的返工轮次（S4 只说有效，没给工时）。