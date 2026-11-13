# refs/ 素材库 v0.2（角色卡优先）

> v0.1 太杂：作品、民俗、角色混在一起。v0.2 只保留两类卡，**角色卡是主体**。
> 只收「国风克苏鲁 / 道诡气质」的东西；纯民俗恐怖不入主库（见 works.md 末尾排除清单）。

## 1. 两类卡
- **角色卡 C-xxxx（主体）**：任何可能出场的角色——己方、敌方、NPC、规则实体——都用同一套维度填。叙事层 + 游戏功能层都要有。
- **作品特征卡 W-xxxx（出处）**：只记「这部作品独特在哪、命名法、世界架构、可偷的点」，不写长剧情。
- 民俗母题不单独建卡，作为作品特征卡里的一个字段；以后真要用再抽出来。

## 2. 角色卡 12 组维度

| 组 | 字段 | 说明 |
|---|---|---|
| A 来源 | source | 作品、作者、媒介/年份、出处链接 |
| B 一句话 | logline | 他是谁 + 想要什么 + 卡在哪 |
| C 世界架构 | world_arch | 属于哪种世界系统（双世界/境界/私坛神系/规则空间/异象地理/组织/时间/宗族），他在系统里的位置 |
| D 身份与称谓 | identity | 本名、道号/诨名、他称；职业/职位；阵营/家族/机构；时代地域；师承/血缘/契约 |
| E 外观与语言 | visual_voice | 一眼识别的视觉符号；口音/口癖/常用词/诵念 |
| F 性格与动机 | psyche | 欲望、恐惧、秘密、道德灰度、底线 |
| G 能力与代价 | power | 能力/功法/仪式/道具；代价/禁忌/触发条件；战斗与非战斗能力 |
| H **游戏功能** | game_function | 见下节，任何角色必填 |
| I 机制映射 | mechanic_map | 可变成命格/规矩/污染/元素/遭遇/叙事中的什么；适配分 |
| J 台词样例 | voice_lines | 3 句台词（初见/威胁/结局），给命名和语言做参考 |
| K 命名法拆解 | naming | 名字结构、用字偏好、可生成的新名字、禁用的字/避免直接复用 |
| L 归档 | meta | 标签、状态、版权风险、来源、更新日期 |

## 3. 「游戏功能」（H）字段——己方/敌方通用
- **side**：player（可操作）/ ally（可招募/跟随）/ npc（中立）/ hostile（敌对）/ rule-entity（规则实体，不可用常规战斗解决）/ boss
- **function**：战斗 / 辅助 / 治疗 / 交易 / 情报 / 任务 / 导师 / 守关 / 事件触发 / 规则执行 / 提供命格 / 容器 / 召唤 / 环境威胁
- **spawn**：出现在哪一层/区域/事件类型；开局 / 中期 / 终局
- **interaction**：对话 / 交易 / 战斗 / 献祭 / 试炼 / 跟随 / 契约
- **reward**：掉落 / 解锁 / 情报 / 命格 / 材料
- **recurrence**：一次性 / 反复出现 / 随机事件
- **threat**：威胁等级 1–5
- **variants**：同功能的 2–3 个换皮变体（防止只有一张皮）

## 4. 作品特征卡（W）
必填：title / author / medium / year / source / one_liner / **uniqueness**（为什么收）/ world_arch / naming（3–5 个例名 + 规则）/ horror_core / stealable（可偷的命名、架构、角色功能）/ cthulhu_score（1–5）/ verdict（收 / 观察 / 排除）。

## 5. 受控词表
- medium：novel / webnovel / game / film / animation / comic / rules-horror / scp
- horror_engine：cognition / rule / body / folk / family / history / system
- side：player / ally / npc / hostile / rule-entity / boss
- function：combat / support / trade / intel / quest / mentor / gatekeeper / event / rule / fate / vessel / summon / hazard
- system_map：fate / rule / pollution / reaction / encounter / narrative
- motif：paper / red-white / mask / talisman / incense / water / fog / eye / mirror / mansion / village / urban / cave / temple

## 6. 评分（选素材用）
恐怖引擎强度 / 命格耦合 / 规矩耦合 / 污染耦合 / solo 可做性 / 原创空间 / 版权风险（1–5，风险反向）。
角色卡只打「适配分 1–5 + 一句理由」，不再面面俱到。

## 7. 目录
```
refs/
  README.md               # 本文件
  works.md                # 收哪些作品、为什么、特征/命名/架构
  naming.md               # 命名法拆解 + 原创名字种子 + 世界架构种子
  cards/_examples.yaml    # 示例角色卡（己方/敌方/NPC/规则实体）
```

## 8. 状态与工作流
raw → analyzed（填完 A–H）→ mapped（I 能对应到系统）→ prototyped（30 秒纸面/灰盒）→ archived。
规则：**没有 game_function 的角色卡不完整**；没有命名拆解的作品卡不完整。

## 9. 版权与红线
只借机制 / 结构 / 母题；不直接使用角色名、专有设定、标志性桥段；改编需授权。
迷信/邪教/血腥题材注意平台与版号风险；做「民俗恐怖表达」，不做「封建迷信宣传」。
