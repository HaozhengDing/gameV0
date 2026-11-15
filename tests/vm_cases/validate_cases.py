#!/usr/bin/env python3
"""T1 符箓 VM 用例结构自检（validate_cases.py）。

用法：
    python3 tests/vm_cases/validate_cases.py            # 从任意目录跑，默认仓库根
    python3 tests/vm_cases/validate_cases.py <root>

规则来源：docs/tech/talisman-vm-spec.md §6.5。只做「结构 + 算术 + 不变量」自检，
不实现参考 VM（T3 的活），但会重算每条用例的灵力/神智/回符/限制事件是否与期望自洽。

退出码：0 通过；1 有错误；2 缺 pyyaml。
"""
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: 缺少 pyyaml（pip install pyyaml）", file=sys.stderr)
    sys.exit(2)

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CASE_DIR = ROOT / "tests" / "vm_cases"

ERRORS = []
WARNINGS = []


def err(msg):
    ERRORS.append(msg)


def warn(msg):
    WARNINGS.append(msg)


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def load_yaml(path, label):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        err("%s: YAML 解析失败: %s" % (label, exc))
        return None


# ---------------------------------------------------------------- 常量（spec §3.2 / §4.3 / §6.4）
CATEGORIES = {
    "basic", "head", "foot_attach", "multi_body", "cursor", "shuffle",
    "phantom_slot", "no_spirit", "boundary", "invalid_sentence",
    "forbidden_phantom", "round", "refund", "trigger", "limits",
}
EVENT_CODES = {
    "rejected_recharging", "rejected_empty_deck", "fizzle_no_spirit",
    "invalid_sentence", "forbidden_read", "backlash_armed", "backlash_consumed",
    "phantom_substitute", "phantom_slot_added", "phantom_slot_cleared",
    "depth_limit", "empty_trigger", "sub_fizzle_no_spirit",
    "budget_exhausted_action", "budget_exhausted_projectile", "round_end",
}
REJECT_REASONS = {"recharging", "empty_deck"}
TRIGGER_KINDS = {"on_hit", "on_expire"}
MATERIAL_KEYS = ("material", "to", "removes", "produces")

OP_REQUIRED = {
    "spawn_projectile": ["spell"],
    "explode": ["radius", "damage", "damage_type"],
    "damage": ["amount", "damage_type"],
    "ignite": ["duration"],
    "spawn_cloud": ["kind", "radius", "duration"],
    "purify": ["removes"],
    "barrier": ["effect"],
    "grant_temp_slot": [],
    "convert_material": ["source", "to"],
    "spawn_material": ["material", "shape"],
    "dig": ["radius"],
    "apply_status": ["status", "duration"],
    "extinguish_lantern": ["lanterns"],
    "drain_life": ["amount"],
    "refund_spirit": ["amount"],
    "phantom_cast": ["spell", "reason", "effect"],
}
OP_KEYS = {
    "spawn_projectile": {"op", "from", "spell", "count", "damage", "damage_type",
                         "element", "pierce", "speed", "spread_deg", "ttl_ticks",
                         "payloads", "trigger"},
    "explode": {"op", "from", "radius", "damage", "damage_type"},
    "damage": {"op", "from", "amount", "damage_type", "radius"},
    "ignite": {"op", "from", "duration", "spread", "damage_per_sec", "produces", "target_tags"},
    "spawn_cloud": {"op", "from", "kind", "radius", "duration", "damage",
                    "damage_per_sec", "damage_type", "tags"},
    "purify": {"op", "from", "removes", "radius"},
    "barrier": {"op", "from", "effect", "radius", "duration"},
    "grant_temp_slot": {"op", "from", "value", "duration"},
    "convert_material": {"op", "from", "source", "to", "radius"},
    "spawn_material": {"op", "from", "material", "shape", "count", "radius", "duration"},
    "dig": {"op", "from", "radius", "mode"},
    "apply_status": {"op", "from", "status", "duration"},
    "extinguish_lantern": {"op", "from", "lanterns"},
    "drain_life": {"op", "from", "amount"},
    "refund_spirit": {"op", "from", "amount"},
    "phantom_cast": {"op", "from", "spell", "reason", "effect", "payloads"},
}
OPS = set(OP_KEYS)
INV_LHS = {
    "accepted", "action_count", "spawn_count", "max_depth", "spirit_after",
    "sanity_after", "cursor_after", "ready_at_tick_after", "round_ended",
    "backlash_after", "phantom_slots_after", "consumed_count",
}
INV_RE = re.compile(r"^([a-z_]+)\s*(==|!=|<=|>=|<|>)\s*(.+)$")
WAND_KEYS = {"spirit", "spirit_max", "regen_per_sec", "slots", "sentences_per_cast",
             "recharge_ticks", "ready_at_tick", "ordered", "deck", "cursor"}
CASE_KEYS = {"id", "title", "category", "spec", "initial", "input", "expect"}
EXPECT_KEYS = {"accepted", "reject_reason", "actions", "summary", "consumed", "spirit_after",
               "sanity_after", "backlash_after", "phantom_slots_after", "cursor_after",
               "round_ended", "ready_at_tick_after", "event_codes", "invariants"}


# ---------------------------------------------------------------- 加载数据
def load_cards():
    doc = load_yaml(CASE_DIR / "cards.yaml", "cards.yaml") or {}
    cards, phantoms = {}, {}
    for seg in ("head", "body", "foot"):
        items = (doc.get("segments") or {}).get(seg) or []
        for card in items:
            cid = card.get("id")
            if not cid:
                err("cards.yaml: %s 里有卡缺 id" % seg)
                continue
            if cid in cards:
                err("cards.yaml: 重复卡 id %s" % cid)
            if not is_int(card.get("spirit_cost")) or card["spirit_cost"] < 0:
                err("cards.yaml: %s 的 spirit_cost 必须是非负整数" % cid)
            cards[cid] = dict(card, segment=seg)
    for ph in doc.get("phantom_pool") or []:
        pid = ph.get("id")
        if not pid:
            err("cards.yaml: phantom_pool 里有幻符缺 id")
        elif pid in cards:
            err("cards.yaml: 幻符与符卡重名 %s" % pid)
        else:
            phantoms[pid] = ph
    return cards, phantoms


def load_materials():
    path = ROOT / "data" / "materials.json"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        err("data/materials.json: 读取失败: %s" % exc)
        return set()
    return {m["id"] for m in doc.get("materials", []) if m.get("id")}


# ---------------------------------------------------------------- 动作校验
def check_action(a, where, ctx, depth=0):
    cards, phantoms, mats = ctx["cards"], ctx["phantoms"], ctx["mats"]
    if not isinstance(a, dict):
        err("%s: 动作必须是对象" % where)
        return
    op = a.get("op")
    if op not in OPS:
        err("%s: 未知动作 op=%r" % (where, op))
        return
    unknown = set(a.keys()) - OP_KEYS[op]
    if unknown:
        err("%s: %s 未知字段 %s" % (where, op, sorted(unknown)))
    for key in OP_REQUIRED[op]:
        if key not in a:
            err("%s: %s 缺必填字段 %s" % (where, op, key))
    if "from" in a and (not isinstance(a["from"], str) or a["from"] not in cards):
        err("%s: 动作来源 from 不是已定义卡 %r" % (where, a.get("from")))
    for key in MATERIAL_KEYS:
        if key in a and a[key] is not None and a[key] not in mats:
            err("%s: %s 引用了 data/materials.json 未定义物质 %r" % (where, key, a[key]))

    if op == "spawn_projectile":
        spell = a.get("spell")
        if spell not in cards:
            err("%s: spawn 的符胆 %r 未定义" % (where, spell))
        elif cards[spell]["segment"] != "body":
            err("%s: spawn 的 %r 不是符胆" % (where, spell))
        for key in ("damage", "speed", "spread_deg"):
            if key in a and not is_num(a[key]):
                err("%s: spawn.%s 必须是数字" % (where, key))
        for key in ("count", "pierce", "ttl_ticks"):
            if key in a and (not is_int(a[key]) or a[key] < 0):
                err("%s: spawn.%s 必须是非负整数" % (where, key))
        if "count" in a and a["count"] < 1:
            err("%s: spawn.count 必须 ≥1" % where)
        payloads = a.get("payloads", [])
        if not isinstance(payloads, list):
            err("%s: spawn.payloads 必须是数组" % where)
        else:
            for i, item in enumerate(payloads):
                check_action(item, "%s.payloads[%d]" % (where, i), ctx, depth)
        trigger = a.get("trigger")
        if trigger is not None:
            check_trigger(trigger, where + ".trigger", ctx, depth)
    elif op == "explode":
        if not is_num(a.get("radius")) or not is_num(a.get("damage")):
            err("%s: explode.radius/damage 必须是数字" % where)
    elif op == "damage":
        if not is_num(a.get("amount")):
            err("%s: damage.amount 必须是数字" % where)
    elif op == "ignite":
        if not is_num(a.get("duration")):
            err("%s: ignite.duration 必须是数字" % where)
        if "spread" in a and not isinstance(a["spread"], bool):
            err("%s: ignite.spread 必须是 bool" % where)
        if "damage_per_sec" in a and not is_num(a["damage_per_sec"]):
            err("%s: ignite.damage_per_sec 必须是数字" % where)
    elif op == "spawn_cloud":
        if a.get("kind") not in {"heat_cloud", "toxic_smoke"}:
            err("%s: spawn_cloud.kind 非法 %r" % (where, a.get("kind")))
        if not is_num(a.get("radius")) or not is_num(a.get("duration")):
            err("%s: spawn_cloud.radius/duration 必须是数字" % where)
    elif op == "purify":
        pass
    elif op == "barrier":
        if not isinstance(a.get("effect"), str):
            err("%s: barrier.effect 必须是字符串" % where)
    elif op == "convert_material":
        source = a.get("source")
        if not isinstance(source, dict) or not ({"material", "tags"} & set(source)):
            err("%s: convert_material.source 必须是 {material} 或 {tags}" % where)
        elif "material" in source and source["material"] not in mats:
            err("%s: convert_material.source.material 未定义" % where)
    elif op == "spawn_material":
        if a.get("shape") not in {"pool", "cloud", "solid"}:
            err("%s: spawn_material.shape 非法 %r" % (where, a.get("shape")))
        for key in ("count", "radius", "duration"):
            if key in a and not is_num(a[key]):
                err("%s: spawn_material.%s 必须是数字" % (where, key))
    elif op == "dig":
        if not is_num(a.get("radius")):
            err("%s: dig.radius 必须是数字" % where)
    elif op == "apply_status":
        if a.get("status") not in {"stun", "slow"}:
            err("%s: apply_status.status 非法 %r" % (where, a.get("status")))
        if not is_num(a.get("duration")):
            err("%s: apply_status.duration 必须是数字" % where)
    elif op == "extinguish_lantern":
        if not is_num(a.get("lanterns")):
            err("%s: extinguish_lantern.lanterns 必须是数字" % where)
    elif op in {"drain_life", "refund_spirit"}:
        if not is_num(a.get("amount")):
            err("%s: %s.amount 必须是数字" % (where, op))
    elif op == "phantom_cast":
        if a.get("spell") not in phantoms:
            err("%s: phantom_cast.spell %r 不在幻符池" % (where, a.get("spell")))
        if a.get("reason") not in {"backlash", "substitute"}:
            err("%s: phantom_cast.reason 非法 %r" % (where, a.get("reason")))
        check_action(a.get("effect"), where + ".effect", ctx, 0)
        payloads = a.get("payloads", [])
        if not isinstance(payloads, list):
            err("%s: phantom_cast.payloads 必须是数组" % where)
        else:
            for i, item in enumerate(payloads):
                check_action(item, "%s.payloads[%d]" % (where, i), ctx, depth)


def check_trigger(trigger, where, ctx, depth):
    if not isinstance(trigger, dict):
        err("%s: trigger 必须是对象" % where)
        return
    unknown = set(trigger.keys()) - {"kind", "depth", "actions"}
    if unknown:
        err("%s: trigger 未知字段 %s" % (where, sorted(unknown)))
    if trigger.get("kind") not in TRIGGER_KINDS:
        err("%s: trigger.kind 非法 %r" % (where, trigger.get("kind")))
    trig_depth = trigger.get("depth")
    if not is_int(trig_depth) or trig_depth < 1:
        err("%s: trigger.depth 必须是 ≥1 的整数" % where)
    elif trig_depth != depth + 1:
        err("%s: trigger.depth 应为 %d（父动作 depth=%d）" % (where, depth + 1, depth))
    elif trig_depth > 3:
        err("%s: trigger.depth 超过建议上限 3" % where)
    actions = trigger.get("actions")
    if not isinstance(actions, list) or not actions:
        err("%s: trigger.actions 必须是非空数组" % where)
        return
    for i, item in enumerate(actions):
        check_action(item, "%s.actions[%d]" % (where, i), ctx, trig_depth)


# ---------------------------------------------------------------- 统计
def exec_count(a):
    if a.get("op") != "spawn_projectile":
        return 1
    n = a.get("count", 1)
    sub = sum(exec_count(p) for p in (a.get("payloads") or []))
    trigger = a.get("trigger")
    if trigger:
        sub += sum(exec_count(x) for x in (trigger.get("actions") or []))
    return n * (1 + sub)


def spawn_total(a):
    if a.get("op") != "spawn_projectile":
        return 0
    n = a.get("count", 1)
    sub = sum(spawn_total(p) for p in (a.get("payloads") or []))
    trigger = a.get("trigger")
    if trigger:
        sub += sum(spawn_total(x) for x in (trigger.get("actions") or []))
    return n + sub


def max_trigger_depth(a):
    best = 0
    trigger = a.get("trigger")
    if a.get("op") == "spawn_projectile" and trigger:
        best = trigger.get("depth", 0)
        for child in trigger.get("actions") or []:
            best = max(best, max_trigger_depth(child))
    for item in a.get("payloads") or []:
        best = max(best, max_trigger_depth(item))
    return best


def action_stats(actions):
    return {
        "action_count": sum(exec_count(a) for a in actions),
        "spawn_count": sum(spawn_total(a) for a in actions),
        "max_depth": max([max_trigger_depth(a) for a in actions] or [0]),
    }


# ---------------------------------------------------------------- 牌堆
def playable_deck(wand, phantom_slots):
    deck = wand.get("deck") or []
    return [c for i, c in enumerate(deck) if c is not None and i not in set(phantom_slots)]


# ---------------------------------------------------------------- 不变量
def eval_invariants(invariants, where, values):
    if not isinstance(invariants, list) or len(invariants) < 3:
        err("%s: invariants 至少 3 条" % where)
        return
    for raw in invariants:
        if not isinstance(raw, str):
            err("%s: invariants 必须是字符串: %r" % (where, raw))
            continue
        match = INV_RE.match(raw.strip())
        if not match:
            err("%s: 不变量语法非法: %r" % (where, raw))
            continue
        lhs, op, rhs_text = match.group(1), match.group(2), match.group(3)
        if lhs not in INV_LHS:
            err("%s: 不变量左值未知: %r" % (where, lhs))
            continue
        try:
            rhs = yaml.safe_load(rhs_text)
        except Exception:  # noqa: BLE001
            err("%s: 不变量右值无法解析: %r" % (where, raw))
            continue
        actual = values.get(lhs)
        ok = compare(actual, op, rhs)
        if not ok:
            err("%s: 不变量不成立: %r（实际 %r）" % (where, raw, actual))


def compare(actual, op, rhs):
    if op in ("==", "!="):
        if isinstance(actual, list) or isinstance(rhs, list):
            equal = actual == rhs
        else:
            equal = actual == rhs
        return equal if op == "==" else not equal
    if not is_num(actual) or not is_num(rhs):
        return False
    if op == "<":
        return actual < rhs
    if op == "<=":
        return actual <= rhs
    if op == ">":
        return actual > rhs
    return actual >= rhs


# ---------------------------------------------------------------- 单条用例
def check_case(case, where, ctx):
    if not isinstance(case, dict):
        err("%s: 用例必须是对象" % where)
        return None
    missing = CASE_KEYS - set(case)
    if missing:
        err("%s: 缺字段 %s" % (where, sorted(missing)))
        return None
    unknown = set(case) - CASE_KEYS
    if unknown:
        err("%s: 未知字段 %s" % (where, sorted(unknown)))
    cid = case.get("id")
    if not isinstance(cid, str) or not re.match(r"^VM-\d{3}$", cid):
        err("%s: id 必须是 VM-NNN 形式: %r" % (where, cid))
    if not isinstance(case.get("title"), str) or not case["title"].strip():
        err("%s: title 不能为空" % where)
    cats = case.get("category")
    if not isinstance(cats, list) or not cats:
        err("%s: category 必须是非空数组" % where)
        cats = []
    for cat in cats:
        if cat not in CATEGORIES:
            err("%s: 未知 category %r" % (where, cat))
    if not isinstance(case.get("spec"), str) or not case["spec"].startswith("§"):
        err("%s: spec 必须形如 \"§2.2\"" % where)

    initial = case.get("initial")
    input_doc = case.get("input")
    if not isinstance(initial, dict) or not isinstance(input_doc, dict):
        err("%s: initial/input 必须是对象" % where)
        return None
    for key in ("tick", "sanity", "backlash", "phantom_slots", "wand"):
        if key not in initial:
            err("%s: initial 缺 %s" % (where, key))
    tick = initial.get("tick")
    sanity = initial.get("sanity")
    backlash = initial.get("backlash")
    phantom_slots = initial.get("phantom_slots", [])
    if not is_int(tick) or tick < 0:
        err("%s: initial.tick 必须是非负整数" % where)
    if not is_int(sanity) or not 0 <= sanity <= 100:
        err("%s: initial.sanity 必须是 0–100 整数" % where)
    if not isinstance(backlash, bool):
        err("%s: initial.backlash 必须是 bool" % where)
    if not isinstance(phantom_slots, list) or any(not is_int(x) for x in phantom_slots):
        err("%s: initial.phantom_slots 必须是整数数组" % where)
        phantom_slots = []

    wand = initial.get("wand") or {}
    unknown_wand = set(wand) - WAND_KEYS
    if unknown_wand:
        err("%s: wand 未知字段 %s" % (where, sorted(unknown_wand)))
    for key in WAND_KEYS:
        if key not in wand:
            err("%s: wand 缺 %s" % (where, key))
    slots = wand.get("slots")
    if not is_int(slots) or not 2 <= slots <= 24:
        err("%s: wand.slots 必须是 2–24 整数" % where)
        slots = 0
    for key in ("spirit", "spirit_max"):
        if not is_num(wand.get(key)):
            err("%s: wand.%s 必须是数字" % (where, key))
    if is_num(wand.get("spirit")) and is_num(wand.get("spirit_max")) and wand["spirit"] > wand["spirit_max"]:
        err("%s: wand.spirit 不能大于 spirit_max" % where)
    if not is_int(wand.get("sentences_per_cast")) or wand["sentences_per_cast"] < 1:
        err("%s: wand.sentences_per_cast 必须是 ≥1 整数" % where)
    if not is_int(wand.get("recharge_ticks")) or wand["recharge_ticks"] < 0:
        err("%s: wand.recharge_ticks 必须是非负整数" % where)
    if not is_int(wand.get("ready_at_tick")):
        err("%s: wand.ready_at_tick 必须是整数" % where)
    if not isinstance(wand.get("ordered"), bool):
        err("%s: wand.ordered 必须是 bool" % where)
    deck = wand.get("deck")
    if not isinstance(deck, list):
        err("%s: wand.deck 必须是数组" % where)
        deck = []
    if len(deck) != slots:
        err("%s: wand.deck 长度 %d 必须等于 slots %d" % (where, len(deck), slots))
    for i, card in enumerate(deck):
        if card is None:
            continue
        if card not in ctx["cards"]:
            err("%s: deck[%d] 引用未定义卡 %r" % (where, i, card))
    for slot in phantom_slots:
        if not is_int(slot) or not 0 <= slot < slots:
            err("%s: phantom_slots 含非法槽位 %r" % (where, slot))
    for slot in phantom_slots:
        if 0 <= slot < len(deck) and deck[slot] in ctx["cards"] and ctx["cards"][deck[slot]].get("forbidden"):
            err("%s: 幻影符不能占据禁符所在槽位 %d" % (where, slot))
    # spec §2.7 第 1 步：sanity ≥33 时幻影符在牌堆构建前清除
    effective_phantom = [] if (is_int(sanity) and sanity >= 33) else phantom_slots
    pdeck = playable_deck(wand, effective_phantom)
    cursor = wand.get("cursor")
    if not is_int(cursor) or not 0 <= cursor <= len(pdeck):
        err("%s: wand.cursor 必须在 0..%d" % (where, len(pdeck)))

    if input_doc.get("op") != "cast":
        err("%s: input.op 目前只允许 cast" % where)
    rng = input_doc.get("rng")
    if not isinstance(rng, dict):
        err("%s: input.rng 必填" % where)
        rng = {}
    for key in ("phantom_roll", "phantom_slot", "phantom_card"):
        if key not in rng:
            err("%s: input.rng 缺 %s" % (where, key))
    roll = rng.get("phantom_roll")
    if not is_num(roll) or not 0 <= roll <= 1:
        err("%s: rng.phantom_roll 必须是 0–1 数字" % where)
    pslot = rng.get("phantom_slot")
    if pslot is not None and (not is_int(pslot) or not 0 <= pslot < slots):
        err("%s: rng.phantom_slot 必须是合法槽位或 null" % where)
    pcard = rng.get("phantom_card")
    if pcard is not None and pcard not in ctx["phantoms"]:
        err("%s: rng.phantom_card 必须是幻符池 id 或 null" % where)

    expect = case.get("expect")
    if not isinstance(expect, dict):
        err("%s: expect 必须是对象" % where)
        return None
    unknown_expect = set(expect) - EXPECT_KEYS
    if unknown_expect:
        err("%s: expect 未知字段 %s" % (where, sorted(unknown_expect)))
    for key in ("accepted", "reject_reason", "consumed", "spirit_after", "sanity_after",
                "backlash_after", "phantom_slots_after", "cursor_after", "round_ended",
                "ready_at_tick_after", "event_codes", "invariants"):
        if key not in expect:
            err("%s: expect 缺 %s" % (where, key))
    if "actions" not in expect and "summary" not in expect:
        err("%s: expect 需要 actions 或 summary" % where)

    accepted = expect.get("accepted")
    reject_reason = expect.get("reject_reason")
    consumed = expect.get("consumed") or []
    if not isinstance(accepted, bool):
        err("%s: expect.accepted 必须是 bool" % where)
    if accepted:
        if reject_reason is not None:
            err("%s: accepted=true 时 reject_reason 必须为 null" % where)
    else:
        if reject_reason not in REJECT_REASONS:
            err("%s: accepted=false 时 reject_reason 必须是 %s" % (where, sorted(REJECT_REASONS)))
        if expect.get("actions"):
            err("%s: 拒绝施法不应有动作" % where)
        if consumed:
            err("%s: 拒绝施法不应有 consumed" % where)
    if not isinstance(consumed, list):
        err("%s: expect.consumed 必须是数组" % where)
        consumed = []
    for card in consumed:
        if card not in ctx["cards"]:
            err("%s: consumed 引用未定义卡 %r" % (where, card))
    start = cursor if is_int(cursor) else 0
    if consumed and consumed != pdeck[start:start + len(consumed)]:
        err("%s: consumed 必须等于牌堆 cursor 起的连续切片" % where)

    actions = expect.get("actions")
    if actions is not None:
        if not isinstance(actions, list):
            err("%s: expect.actions 必须是数组" % where)
            actions = []
        for i, action in enumerate(actions):
            check_action(action, "%s.expect.actions[%d]" % (where, i), ctx)
    stats = action_stats(actions or [])
    summary = expect.get("summary")
    if summary is not None:
        if not isinstance(summary, dict):
            err("%s: expect.summary 必须是对象" % where)
        else:
            for key in ("action_count", "spawn_count", "max_depth"):
                if not is_int(summary.get(key)):
                    err("%s: expect.summary.%s 必须是整数" % (where, key))
                elif actions is not None and summary.get(key) != stats[key]:
                    err("%s: expect.summary.%s=%r 与 actions 推导值 %r 不一致"
                        % (where, key, summary.get(key), stats[key]))
            stats = {k: summary.get(k, stats[k]) for k in ("action_count", "spawn_count", "max_depth")}

    events = expect.get("event_codes")
    if not isinstance(events, list) or any(e not in EVENT_CODES for e in events):
        err("%s: event_codes 含未知事件码" % where)
        events = events if isinstance(events, list) else []

    # ---- 算术自洽：灵力
    spirit = wand.get("spirit", 0)
    spirit_max = wand.get("spirit_max", 0)

    def cost(card):
        return ctx["cards"][card]["spirit_cost"]

    def refund(card):
        info = ctx["cards"][card]
        action = info.get("action") or {}
        if info.get("timing") == "sentence_end" and action.get("op") == "refund_spirit":
            return action.get("amount", 0)
        return 0

    cost_sum = sum(cost(c) for c in consumed if c in ctx["cards"])
    refund_sum = sum(refund(c) for c in consumed if c in ctx["cards"])
    if not accepted:
        expected_spirit = spirit
    elif backlash:
        expected_spirit = spirit - min(spirit, cost_sum)
    else:
        expected_spirit = clamp(spirit - cost_sum + refund_sum, 0, spirit_max)
    spirit_after = expect.get("spirit_after")
    if is_num(spirit_after) and abs(spirit_after - expected_spirit) > 1e-9:
        err("%s: spirit_after=%r 与算术推导 %r 不符（cost=%r refund=%r）"
            % (where, spirit_after, expected_spirit, cost_sum, refund_sum))
    if is_num(spirit_after) and not (0 <= spirit_after <= spirit_max):
        err("%s: spirit_after 越界 [0, spirit_max]" % where)

    # ---- 算术自洽：神智
    forbidden = sum(1 for c in consumed if c in ctx["cards"] and ctx["cards"][c].get("forbidden"))
    if accepted and not backlash:
        expected_sanity = max(0, sanity - 20 * forbidden)
    else:
        expected_sanity = sanity
    sanity_after = expect.get("sanity_after")
    if is_int(sanity_after) and sanity_after != expected_sanity:
        err("%s: sanity_after=%r 与算术推导 %r 不符（禁符 %d 张）"
            % (where, sanity_after, expected_sanity, forbidden))

    # ---- 反噬
    expected_backlash = backlash if not accepted else (False if backlash else forbidden > 0)
    if isinstance(expect.get("backlash_after"), bool) and expect["backlash_after"] != expected_backlash:
        err("%s: backlash_after=%r 应为 %r" % (where, expect["backlash_after"], expected_backlash))

    # ---- 幻影符
    ph_after = expect.get("phantom_slots_after")
    if not isinstance(ph_after, list) or any(not is_int(x) for x in ph_after):
        err("%s: phantom_slots_after 必须是整数数组" % where)
        ph_after = []
    if is_int(sanity_after):
        if (sanity_after < 33) != (len(ph_after) > 0):
            err("%s: I2 不成立：sanity_after<33 ⇔ phantom_slots_after 非空" % where)
        if len(ph_after) > 1:
            err("%s: phantom_slots_after 最多 1 格（magic_numbers.sanity.phantom_slots）" % where)
        if sanity_after >= 33 and ph_after:
            err("%s: 神智 ≥33 时不应有幻影符" % where)
    for slot in ph_after:
        if not 0 <= slot < slots:
            err("%s: phantom_slots_after 槽位越界 %r" % (where, slot))
        if 0 <= slot < len(deck) and deck[slot] in ctx["cards"] and ctx["cards"][deck[slot]].get("forbidden"):
            err("%s: 幻影符占据禁符槽位 %d" % (where, slot))
    if "phantom_substitute" in events and is_int(sanity_after) and sanity_after != sanity:
        err("%s: I5 不成立：15%% 替换时神智不应变化" % where)

    # ---- 回符
    round_ended = expect.get("round_ended")
    cursor_after = expect.get("cursor_after")
    ready_after = expect.get("ready_at_tick_after")
    recharge = wand.get("recharge_ticks", 0)
    if not isinstance(round_ended, bool):
        err("%s: round_ended 必须是 bool" % where)
    elif not is_int(cursor_after):
        err("%s: cursor_after 必须是整数" % where)
    elif round_ended:
        if cursor_after != 0:
            err("%s: 回符后 cursor_after 必须归零" % where)
        if ready_after != tick + recharge:
            err("%s: 回符后 ready_at_tick_after 应为 %r" % (where, tick + recharge))
    else:
        if cursor_after != start + len(consumed):
            err("%s: 未回符时 cursor_after 应为 %r" % (where, start + len(consumed)))
        if ready_after != wand.get("ready_at_tick"):
            err("%s: 未回符时 ready_at_tick_after 应不变" % where)

    # ---- 事件一致性
    if ("round_end" in events) != bool(round_ended):
        err("%s: round_end 事件与 round_ended 不一致" % where)
    if accepted and "rejected_recharging" in events:
        err("%s: 已受理的施法不应带 rejected_recharging" % where)
    if not accepted and not (set(events) & {"rejected_recharging", "rejected_empty_deck"}):
        err("%s: 被拒绝的施法必须带 rejected_* 事件" % where)
    if "rejected_recharging" in events and is_int(wand.get("ready_at_tick")) and tick >= wand["ready_at_tick"]:
        err("%s: rejected_recharging 需满足 tick < ready_at_tick" % where)
    if "backlash_consumed" in events and not backlash:
        err("%s: backlash_consumed 需初始 backlash=true" % where)
    if "forbidden_read" in events and (backlash or forbidden == 0):
        err("%s: forbidden_read 需非反噬施法且读完禁符" % where)
    if "phantom_substitute" in events:
        if backlash or forbidden or not (sanity < 33) or not (is_num(roll) and roll < 0.15):
            err("%s: phantom_substitute 条件不满足（需 sanity<33、非反噬、无禁符、roll<0.15）" % where)
    if "fizzle_no_spirit" in events and (actions or consumed):
        err("%s: fizzle_no_spirit 不应有动作/读牌" % where)
    if "budget_exhausted_action" in events and stats["action_count"] != 64:
        err("%s: budget_exhausted_action 时 action_count 应被钳到 64" % where)
    if "budget_exhausted_projectile" in events and stats["spawn_count"] != 32:
        err("%s: budget_exhausted_projectile 时 spawn_count 应被钳到 32" % where)
    if "depth_limit" in events and stats["max_depth"] != 3:
        err("%s: depth_limit 时 max_depth 应为 3" % where)
    if "phantom_slot_added" in events and len(ph_after) <= len(phantom_slots):
        err("%s: phantom_slot_added 但幻影符没有增加" % where)
    if "phantom_slot_cleared" in events and ph_after:
        err("%s: phantom_slot_cleared 但仍有幻影符" % where)
    if "invalid_sentence" in events and not consumed:
        err("%s: invalid_sentence 必须有读出的符（consumed）" % where)

    # ---- 派生值 + 不变量
    values = {
        "accepted": accepted,
        "action_count": stats["action_count"],
        "spawn_count": stats["spawn_count"],
        "max_depth": stats["max_depth"],
        "spirit_after": spirit_after,
        "sanity_after": sanity_after,
        "cursor_after": cursor_after,
        "ready_at_tick_after": ready_after,
        "round_ended": round_ended,
        "backlash_after": expect.get("backlash_after"),
        "phantom_slots_after": ph_after,
        "consumed_count": len(consumed),
    }
    eval_invariants(expect.get("invariants"), where, values)
    return {"id": cid, "category": cats, "events": events, "stats": stats}


# ---------------------------------------------------------------- 主流程
def main():
    ctx = {"cards": {}, "phantoms": {}, "mats": set()}
    ctx["cards"], ctx["phantoms"] = load_cards()
    ctx["mats"] = load_materials()
    if not ctx["cards"]:
        err("cards.yaml 没有可用卡")

    manifest_path = CASE_DIR / "manifest.yaml"
    manifest = load_yaml(manifest_path, "manifest.yaml") or {}
    files = manifest.get("files") or []
    if not files:
        err("manifest.yaml: 没有 files")

    results = []
    seen = set()
    for entry in files:
        rel = entry.get("path")
        if not isinstance(rel, str):
            err("manifest.yaml: files 项缺 path")
            continue
        path = ROOT / rel
        doc = load_yaml(path, rel) or {}
        if doc.get("schema") != "gamev0.vm_cases/v0.1":
            err("%s: schema 应为 gamev0.vm_cases/v0.1" % rel)
        cases = doc.get("cases") or []
        if not isinstance(cases, list):
            err("%s: cases 必须是数组" % rel)
            continue
        if len(cases) != entry.get("cases"):
            err("%s: 用例数 %d 与 manifest 的 %r 不一致" % (rel, len(cases), entry.get("cases")))
        for i, case in enumerate(cases):
            where = "%s[%d] %s" % (path.name, i, case.get("id") if isinstance(case, dict) else "?")
            info = check_case(case, where, ctx)
            if info is None:
                continue
            if info["id"] in seen:
                err("%s: id 重复" % where)
            seen.add(info["id"])
            results.append(info)

    total = len(results)
    if total != 30:
        err("用例总数 %d，应为 30" % total)
    if manifest.get("total_cases") != total:
        err("manifest.total_cases=%r 与实际 %d 不一致" % (manifest.get("total_cases"), total))

    counts = {}
    for info in results:
        for cat in info["category"]:
            counts[cat] = counts.get(cat, 0) + 1
    declared = manifest.get("category_counts") or {}
    for cat, n in sorted(counts.items()):
        if declared.get(cat) != n:
            err("manifest.category_counts[%s]=%r 与实际 %d 不一致" % (cat, declared.get(cat), n))
    for cat, n in declared.items():
        if counts.get(cat) != n:
            err("manifest.category_counts[%s] 声明 %d 实际 %d" % (cat, n, counts.get(cat, 0)))
    for cat, need in (manifest.get("category_minimums") or {}).items():
        if counts.get(cat, 0) < need:
            err("类别 %s 只有 %d 条，要求 ≥%d" % (cat, counts.get(cat, 0), need))

    all_events = set()
    for info in results:
        all_events |= set(info["events"])
    for code in manifest.get("required_limit_events") or []:
        if code not in all_events:
            err("没有任何用例覆盖上限事件 %s" % code)

    print("cards: %d | phantom: %d | materials: %d"
          % (len(ctx["cards"]), len(ctx["phantoms"]), len(ctx["mats"])))
    print("cases: %d" % total)
    print("categories: " + ", ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)))
    for msg in WARNINGS:
        print("WARN: " + msg)
    if ERRORS:
        print("\nFAIL: %d 个错误" % len(ERRORS), file=sys.stderr)
        for msg in ERRORS:
            print(" - " + msg, file=sys.stderr)
        return 1
    print("OK: 30 条用例结构自检通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
