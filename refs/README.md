# 素材库（refs）地基 v0.1

> 目标：把「国风克苏鲁 / 中式怪谈」的优秀作品，拆成可检索、可评分、可映射到我们玩法（命格 / 规矩 / 污染 / 元素）的卡片。
> 卡片是设计参考，不是改编素材；只借机制、结构、母题，不搬名字与专有设定。

## 0. 设计目标
1. 每张卡回答三个问题：**它为什么可怕？它的规则是什么？它能变成我们的什么机制？**
2. 支撑三个系统：命格（开局 build）、规矩（规则怪谈式引导）、污染（认知/资源）。
3. 可被检索：标签、评分、来源、状态齐全，换个人也能接着用。

## 1. 三类卡片

### 1.1 作品卡（W-0001）
一本书 / 一部游戏 / 一部电影的「世界观 + 恐怖引擎」。

| 字段 | 说明 | 必填 |
|---|---|---|
| id | W-0001 | ✅ |
| title / alias | 标题 / 别名 | ✅ |
| author | 作者 / 团队 / 导演 / 工作室 | ✅ |
| medium | novel / webnovel / game / film / animation / comic / rules-horror / scp | ✅ |
| year | 年份（不确定写「约」并标注） | ✅ |
| sources | 链接：主创访谈 / 百科 / Steam / 豆瓣 / 原文 | ✅ |
| logline | 一句话概括 | ✅ |
| world | 时代 / 地域 / 民俗基底 | ✅ |
| anomaly_rules | 这个世界「不讲理」的核心规则 / 禁忌 | ✅ |
| horror_engine | 恐惧来源：cognition / rule / body / folk / social / family / history / system | ✅ |
| narrative_structure | 双世界 / 单元 / 循环 / 不可靠叙述 / 碎片考据 | ✅ |
| cast | 关联角色卡 id | ⬜ |
| motifs | 关联母题卡 id | ⬜ |
| transferable | 能抽象成我们的什么系统 / 关卡 / 事件 | ✅ |
| risk | 版权 / 敏感 / 同质化 | ✅ |
| tags | 受控词表 | ✅ |
| status | raw / analyzed / mapped / prototyped / archived | ✅ |

### 1.2 角色卡（C-0001）—— 素材库主体
| 字段 | 说明 | 必填 |
|---|---|---|
| id | C-0001 | ✅ |
| name / alias | 姓名 / 称谓 | ✅ |
| source | 作品 id + 标题 + 作者 + 媒介 | ✅ |
| identity | 身份 / 职业（警察、风水师、神婆、道士、主播、剧作家、学生…） | ✅ |
| affiliation | 阵营 / 家族 / 组织 / 教派 | ✅ |
| era_place | 时代 / 地域 | ✅ |
| story_role | protagonist / antagonist / guide / witness / vessel / rule-incarnate / victim / accomplice | ✅ |
| anomaly_relation | investigator / believer / sacrifice / vessel / contract / symbiosis / seal / enforcer | ✅ |
| desire | 想要什么（一句话） | ✅ |
| fear | 怕什么 / 弱点 | ✅ |
| secret | 秘密 / 谎言 / 不可靠点 | ✅ |
| ability | 能力 / 仪式 / 道具 | ✅ |
| cost | 代价 / 限制 / 触发条件 | ✅ |
| signature | 代表场景 / 台词 / 桥段 | ✅ |
| visual_motif | 视觉母题（纸扎、红白、符箓、雾、眼、镜…） | ✅ |
| audio_motif | 声音母题（唢呐、木鱼、诵经、方言…） | ⬜ |
| transferable | 可迁移成：命格 / 敌人 / NPC / 事件 / 规则 | ✅ |
| adapt_score | 适配度 1–5 | ✅ |
| risk | 版权 / 敏感 / 同质化 | ✅ |
| tags | 受控词表 | ✅ |
| sources | 出处链接 | ✅ |
| status / updated | 状态 / 更新日期 | ✅ |

### 1.3 母题卡（M-0001）
民俗、空间、物件、仪式——比角色更「可组合」的素材。

| 字段 | 说明 |
|---|---|
| id / motif | M-0001 / 纸扎、冥婚、喜丧、傩戏、赶尸… |
| type | folk / space / object / ritual / body / sound |
| sources | 出处作品 id |
| symbols | 视觉符号 |
| taboos / rules | 禁忌 / 规矩（能直接变成玩法） |
| mechanism | 可转化：资源 / 规则 / 危险 / 遭遇 / 解锁条件 |
| risk | 敏感度（迷信 / 邪教 / 血腥） |
| tags | 受控词表 |

## 2. 受控词表（tags，先定死，避免乱）
- **medium**：novel / webnovel / game / film / animation / comic / rules-horror / scp / folk
- **horror_engine**：cognition（认知）/ rule（规则）/ body（身体）/ folk（民俗）/ social（社会）/ family（家庭）/ history（历史）/ system（系统）
- **story_role**：protagonist / antagonist / guide / witness / vessel / rule-incarnate / victim / accomplice
- **anomaly_relation**：investigator / believer / sacrifice / vessel / contract / symbiosis / seal / enforcer
- **motif**：paper（纸扎）/ red-white（红白）/ mask（傩面）/ talisman（符箓）/ incense（香火）/ water / fog / eye / mirror / mansion（老宅）/ village / urban（城寨/都市）/ cave / temple
- **system_map**：fate（命格）/ rule（规矩）/ pollution（污染）/ reaction（元素反应）/ narrative（叙事）/ encounter（遭遇）/ economy

## 3. 评分维度（每项 1–5，选素材时看总分）
- **恐怖引擎强度**：设定本身是否让人后背发凉。
- **命格耦合**：能否抽象出「能力 + 代价」的开局 build。
- **规矩耦合**：能否抽象成可观察、可违反、有后果的规则。
- **污染耦合**：能否抽象成认知/信息层面的资源。
- **solo 可做性**：做成一个人能实现的 2D / 文字 / 灰盒的成本（越高越省）。
- **原创空间**：借鉴后还能玩出我们自己的东西。
- **版权风险**：低 / 中 / 高（高风险只做机制参考）。

## 4. 命名 / 目录 / 状态
```
refs/
  README.md           # 本文件：维度与规范
  works.md            # 作品清单与剧情概括
  cards/
    _examples.yaml    # 示例：作品卡 + 角色卡
    C-0001_李火旺.yaml
  motifs/
    M-0001_纸扎.yaml
```
- 文件名：`{type}-{四位编号}_{中文名}.yaml`
- 状态流转：raw（只收集）→ analyzed（填完作品/角色卡）→ mapped（对应到游戏系统）→ prototyped（纸面/灰盒验证过）→ archived（弃用，保留记录）

## 5. 填写规范
1. 每个字段一句话，不写空泛形容词。
2. 不确定的内容加 `?`，并在 sources 里写清依据；不编年份、不编作者。
3. 引用原文只保留必要片段，注明出处。
4. 角色卡至少填满：身份、欲望、恐惧、与异常的关系、能力、代价、可迁移点——这七项决定它能不能变成玩法。
5. 每张卡末尾写一句「这张卡教会我们什么」。

## 6. 版权与红线
- 只借**机制 / 结构 / 母题**，不直接使用角色名、专有设定、标志性桥段。
- 《道诡异仙》《双瞳》《咒》等都有明确版权方；改编、续写、商用需授权。
- 涉及迷信 / 邪教 / 血腥的题材，注意国内平台与版号风险；表达上做「民俗恐怖」，不做「封建迷信宣传」。
- 引用他人解析文章时注明链接，不整段搬运。

## 7. 工作流
收集（raw）→ 拆解（analyzed：填作品卡 + 角色卡）→ 映射（mapped：命格/规矩/污染/事件）→ 原型（prototyped：30 秒纸面或灰盒）→ 归档。
每完成 10 张卡，回看一次：哪些能直接进游戏、哪些只是好看。
