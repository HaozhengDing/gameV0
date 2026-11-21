#!/usr/bin/env python3
"""gameV0 数据与卡片校验器（T0）。

用法：
    python3 tools/validate_data.py            # 校验仓库根目录
    python3 tools/validate_data.py <root>     # 校验指定目录（用于破坏性测试）

规则来源：docs/02-m0-plan.md T0。
退出码：0 全过；1 有错误；2 缺依赖。
"""
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: 缺少 pyyaml（pip install pyyaml）", file=sys.stderr)
    sys.exit(2)

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
errors = []
warnings = []

MATERIAL_STATES = {"liquid", "powder", "solid", "gas"}
ELEMENTS = {"金", "木", "水", "火", "土"}
POLARITIES = {"阴", "阳", "none"}
RESULT_TYPES = {
    "explosion", "heat_cloud", "purify", "damage", "barrier",
    "temporary_talisman_slot", "toxic_smoke", "burn",
}
CARD_TYPES = {"character", "work", "system", "talisman", "fate", "location", "event"}
SECONDARY_BURN_PRODUCTS = {"smoke", "toxic_smoke", "steam"}
TEXT_KEY_RE = re.compile(r"^\$[a-z]+_[a-z0-9_]+$")
NON_CORRUPTIBLE_PREFIXES = ("$mat_", "$card_", "$react_", "$status_", "$ui_", "$enemy_")


def err(msg):
    errors.append(msg)


def load_json(rel):
    p = ROOT / rel
    if not p.exists():
        err(f"{rel}: 文件不存在")
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        err(f"{rel}: JSON 解析失败: {e}")
        return None


def load_yaml(rel):
    p = ROOT / rel
    try:
        return yaml.safe_load(p.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        err(f"{rel}: YAML 解析失败: {e}")
        return None


def get_path(obj, path, default=None):
    cur = obj
    for key in path.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def validate_materials():
    data = load_json("data/materials.json")
    if data is None:
        return set(), set(), {}
    mats = data.get("materials")
    reactions = data.get("reactions")
    if not isinstance(mats, list) or not mats:
        err("data/materials.json: materials 必须是非空数组")
        return set(), set(), {}

    raw = {}
    ids = []
    for i, m in enumerate(mats):
        if not isinstance(m, dict):
            err(f"materials[{i}]: 不是对象")
            continue
        mid = m.get("id")
        if not mid:
            err(f"materials[{i}]: 缺少 id")
            continue
        if mid in raw:
            err(f"materials: 重复 id {mid}")
        ids.append(mid)
        raw[mid] = m
    idset = set(ids)

    resolved = {}
    resolving = set()

    def resolve(mid):
        if mid in resolved:
            return resolved[mid]
        if mid in resolving:
            err(f"materials.{mid}: extends 循环引用")
            return dict(raw[mid])
        resolving.add(mid)
        base = {}
        parent = raw[mid].get("extends")
        if parent:
            if parent not in raw:
                err(f"materials.{mid}: extends 引用了未定义物质 {parent}")
            else:
                base = dict(resolve(parent))
        merged = dict(base)
        merged.update({k: v for k, v in raw[mid].items() if k != "extends"})
        resolving.discard(mid)
        resolved[mid] = merged
        return merged

    by_id = {}
    for mid in ids:
        m = resolve(mid)
        by_id[mid] = m
        if m.get("state") not in MATERIAL_STATES:
            err(f"materials.{mid}: state 非法: {m.get('state')}")
        if m.get("element") not in ELEMENTS:
            err(f"materials.{mid}: element 非法: {m.get('element')}")
        if m.get("polarity", "none") not in POLARITIES:
            err(f"materials.{mid}: polarity 非法: {m.get('polarity')}")
        if not isinstance(m.get("density"), (int, float)):
            err(f"materials.{mid}: density 必须是数字")
        if not isinstance(m.get("tags", []), list):
            err(f"materials.{mid}: tags 必须是数组")
        if "burn_time" in m:
            bt = m["burn_time"]
            if not isinstance(bt, int) or isinstance(bt, bool) or bt <= 0:
                err(f"materials.{mid}: burn_time 必须是正整数")
        if "burn_product" in m:
            bp = m["burn_product"]
            if not isinstance(bp, str) or (bp not in idset and bp not in SECONDARY_BURN_PRODUCTS):
                err(f"materials.{mid}: burn_product 引用了未定义物质 {bp!r}")

    if not isinstance(reactions, list):
        err("data/materials.json: reactions 必须是数组")
        return idset, set(), by_id
    rids = []
    for i, r in enumerate(reactions):
        if not isinstance(r, dict):
            err(f"reactions[{i}]: 不是对象")
            continue
        rid = r.get("id")
        if not rid:
            err(f"reactions[{i}]: 缺少 id")
            continue
        if rid in rids:
            err(f"reactions: 重复 id {rid}")
        rids.append(rid)
        inputs = r.get("inputs", [])
        consumes = r.get("consumes", [])
        for name, xs in (("inputs", inputs), ("consumes", consumes)):
            if not isinstance(xs, list):
                err(f"reactions.{rid}: {name} 必须是数组")
                continue
            for x in xs:
                if x not in idset:
                    err(f"reactions.{rid}: {name} 引用了未定义物质 {x}")
        if isinstance(inputs, list) and isinstance(consumes, list):
            if not set(consumes) <= set(inputs):
                err(f"reactions.{rid}: consumes 必须是 inputs 的子集")
        if not isinstance(r.get("priority"), int) or isinstance(r.get("priority"), bool):
            err(f"reactions.{rid}: priority 必须是整数")
        result = r.get("result")
        if not isinstance(result, dict) or result.get("type") not in RESULT_TYPES:
            err(f"reactions.{rid}: result.type 非法: {result}")
    return idset, set(rids), by_id


def validate_magic_numbers():
    data = load_json("data/magic_numbers.json")
    if data is None:
        return
    required = {
        "design.fate_in_mvp": bool,
        "player.hp": (int, float),
        "player.lanterns": (int, float),
        "sanity.thresholds": dict,
        "sanity.possession": dict,
        "sanity.forbidden_backlash": str,
        "fire_heat": dict,
        "fire_heat.fire_source_heat": (int, float),
        "fire_heat.burning_dps_max_hp_ratio": (int, float),
        "economy.silver_base": (int, float),
        "economy.silver_per_level": (int, float),
        "economy.yin_money_per_silver": (int, float),
        "economy.yin_money_per_silver_zishi": (int, float),
        "elements.in_damage_formula": bool,
        "layers": list,
        "layer_01": dict,
    }
    for path, typ in required.items():
        val = get_path(data, path)
        if val is None:
            err(f"magic_numbers: 缺少键 {path}")
        elif not isinstance(val, typ) or (typ is bool and isinstance(val, int) and not isinstance(val, bool)):
            err(f"magic_numbers: {path} 类型应为 {typ}")


def load_rooms(material_ids, material_by_id):
    rooms = {}
    for p in sorted((ROOT / "data" / "rooms").glob("*.json")):
        rel = str(p.relative_to(ROOT))
        data = load_json(rel)
        if data is None:
            continue
        rid = data.get("id")
        if not rid:
            err(f"{rel}: 缺少 id")
            continue
        if rid in rooms:
            err(f"rooms: 重复 id {rid}")
        size = data.get("size") or {}
        w, h = size.get("w"), size.get("h")
        grid = data.get("grid")
        legend = data.get("legend") or {}
        if not isinstance(w, int) or not isinstance(h, int):
            err(f"{rel}: size.w/h 必须是整数")
            continue
        if not isinstance(grid, list) or len(grid) != h:
            err(f"{rel}: grid 行数应为 {h}")
            continue
        solid = set()
        solid_chars = set()
        for ch, mat in legend.items():
            if mat != "empty" and mat not in material_ids:
                err(f"{rel}: legend[{ch}] 引用了未定义物质 {mat}")
            m = material_by_id.get(mat)
            if m and m.get("state") == "solid":
                solid_chars.add(ch)
        # 判断实心：按 legend 映射到物质 state
        for y, row in enumerate(grid):
            if not isinstance(row, str) or len(row) != w:
                err(f"{rel}: 第 {y} 行长度应为 {w}")
                continue
            for x, ch in enumerate(row):
                if ch not in legend:
                    err(f"{rel}: 网格字符 {ch!r} 不在 legend 中（{x},{y}）")
        for i, e in enumerate(data.get("entities", [])):
            if not isinstance(e, dict):
                err(f"{rel}: entities[{i}] 不是对象")
                continue
            x, y = e.get("x"), e.get("y")
            if not isinstance(x, int) or not isinstance(y, int):
                err(f"{rel}: entity {e.get('id')} 坐标必须是整数")
                continue
            if not (0 <= x < w and 0 <= y < h):
                err(f"{rel}: entity {e.get('id')} 坐标越界 ({x},{y})")
                continue
            ch = grid[y][x]
            if ch in solid_chars:
                err(f"{rel}: entity {e.get('id')} 落在实心格 ({x},{y})")
        rooms[rid] = {"path": rel, "data": data}
    return rooms


def validate_biomes(room_map, material_by_id, material_ids, reaction_ids):
    for p in sorted((ROOT / "data" / "biomes").glob("*.json")):
        rel = str(p.relative_to(ROOT))
        data = load_json(rel)
        if data is None:
            continue
        bid = data.get("id")
        if not bid:
            err(f"{rel}: 缺少 id")
        room_refs = data.get("rooms", [])
        for r in room_refs:
            ref = r.get("ref") if isinstance(r, dict) else None
            if ref not in room_map:
                err(f"{rel}: rooms 引用了不存在的房间 {ref}")
        hazard_ids = []
        for h in data.get("hazards", []):
            hid = h.get("id")
            hazard_ids.append(hid)
            if h.get("reaction") and h["reaction"] not in reaction_ids:
                err(f"{rel}: hazard {hid} 的 reaction 不存在: {h.get('reaction')}")
            for m in h.get("materials", []) or []:
                if m not in material_ids:
                    err(f"{rel}: hazard {hid} 的 materials 引用未定义物质 {m}")
        rule_ids = []
        for r in data.get("rules", []):
            rid = r.get("id")
            rule_ids.append(rid)
            if r.get("type") not in {"true", "false"}:
                err(f"{rel}: rule {rid} 的 type 必须是 true/false")
        # 房间引用检查
        for r in room_refs:
            ref = r.get("ref")
            if ref not in room_map:
                continue
            room = room_map[ref]["data"]
            for h in room.get("hazards", []):
                if h not in hazard_ids:
                    err(f"{rel}: 房间 {ref} 的 hazard {h} 未在 biome 中定义")
            for rid in room.get("intended_rules", []):
                if rid not in rule_ids:
                    err(f"{rel}: 房间 {ref} 的 rule {rid} 未在 biome 中定义")
        boss = (data.get("spawn_table") or {}).get("boss") or {}
        arena = boss.get("arena")
        if arena and arena not in room_map:
            err(f"{rel}: boss arena 引用了不存在的房间 {arena}")
        for m in boss.get("weak_to", []) or []:
            if m not in material_ids:
                err(f"{rel}: boss weak_to 引用未定义物质 {m}")
        for e in boss.get("resist", []) or []:
            if e not in ELEMENTS:
                err(f"{rel}: boss resist 引用未知五行 {e}")
        for group in ("mobs", "elites"):
            for m in (data.get("spawn_table") or {}).get(group, []) or []:
                if not m.get("entity"):
                    err(f"{rel}: spawn_table.{group} 缺 entity: {m}")


def validate_cards():
    n = 0
    for p in sorted((ROOT / "refs").rglob("*.yaml")):
        rel = str(p.relative_to(ROOT))
        data = load_yaml(rel)
        if data is None:
            continue
        if not isinstance(data, list):
            err(f"{rel}: 顶层必须是数组")
            continue
        ids = set()
        for i, card in enumerate(data):
            if not isinstance(card, dict):
                err(f"{rel}: [{i}] 不是对象")
                continue
            cid = card.get("id")
            ctype = card.get("type")
            if not cid or not ctype:
                err(f"{rel}: [{i}] 缺 id/type")
                continue
            if cid in ids:
                err(f"{rel}: 重复 id {cid}")
            ids.add(cid)
            if ctype not in CARD_TYPES:
                err(f"{rel}: {cid} 未知 type {ctype}")
            if ctype == "character" and not isinstance(card.get("game_function"), dict):
                err(f"{rel}: {cid} 缺 game_function")
            if ctype in {"work", "system", "talisman", "fate", "location", "event"} and not card.get("name") and not card.get("title"):
                err(f"{rel}: {cid} 缺 name/title")
            if "tags" in card and not isinstance(card.get("tags"), list):
                err(f"{rel}: {cid} 的 tags 必须是数组")
            n += 1
    print(f"cards: {n} 张")


TALISMAN_OPS = {
    "spawn_projectile", "explode", "damage", "ignite", "spawn_cloud", "purify", "barrier",
    "grant_temp_slot", "convert_material", "spawn_material", "dig", "apply_status",
    "extinguish_lantern", "drain_life", "refund_spirit", "phantom_cast",
}
TALISMAN_OP_REQUIRED = {
    "spawn_projectile": ["spell"],
    "explode": ["radius", "damage", "damage_type"],
    "damage": ["amount", "damage_type"],
    "ignite": ["duration"],
    "spawn_cloud": ["kind", "radius", "duration"],
    "purify": ["removes"],
    "barrier": ["effect"],
    "convert_material": ["source", "to"],
    "spawn_material": ["material", "shape"],
    "dig": ["radius"],
    "apply_status": ["status", "duration"],
    "extinguish_lantern": ["lanterns"],
    "drain_life": ["amount"],
    "refund_spirit": ["amount"],
    "phantom_cast": ["spell", "reason", "effect"],
}


def _walk_actions(obj):
    """递归找出所有带 op 的动作对象（C-ACT）。"""
    found = []
    if isinstance(obj, dict):
        if isinstance(obj.get("op"), str):
            found.append(obj)
        for v in obj.values():
            found.extend(_walk_actions(v))
    elif isinstance(obj, list):
        for v in obj:
            found.extend(_walk_actions(v))
    return found


def _action_material_refs(obj):
    """动作里引用的物质 id：material/to/removes/produces + source.material。"""
    refs = []
    if isinstance(obj, dict):
        for key in ("material", "to", "removes", "produces"):
            if isinstance(obj.get(key), str):
                refs.append(obj[key])
        if isinstance(obj.get("source"), dict) and isinstance(obj["source"].get("material"), str):
            refs.append(obj["source"]["material"])
        for v in obj.values():
            refs.extend(_action_material_refs(v))
    elif isinstance(obj, list):
        for v in obj:
            refs.extend(_action_material_refs(v))
    return refs


def validate_talismans(material_ids):
    """校验 data/talismans.json（C-VM 正式卡表）：结构 + 动作 + 物质引用 + 组成本 + 与用例/卡片的交叉一致性。"""
    data = load_json("data/talismans.json")
    if data is None:
        return
    for key in ("schema", "version", "updated"):
        if not data.get(key):
            err(f"data/talismans.json: 缺少 {key}")

    cards = data.get("cards") or {}
    by_id = {}
    segment_of = {}
    section_names = {"heads": "head", "bodies": "body", "feet": "foot"}
    for section, segment in section_names.items():
        arr = cards.get(section)
        if not isinstance(arr, list) or not arr:
            err(f"data/talismans.json: cards.{section} 必须是非空数组")
            continue
        for i, card in enumerate(arr):
            if not isinstance(card, dict):
                err(f"data/talismans.json: cards.{section}[{i}] 不是对象")
                continue
            cid = card.get("id")
            if not cid:
                err(f"data/talismans.json: cards.{section}[{i}] 缺 id")
                continue
            if cid in by_id:
                err(f"data/talismans.json: 重复 id {cid}")
            by_id[cid] = card
            segment_of[cid] = segment
            if not card.get("name"):
                err(f"data/talismans.json: {cid} 缺 name")
            cost = card.get("spirit_cost")
            if not isinstance(cost, (int, float)) or isinstance(cost, bool) or cost < 0:
                err(f"data/talismans.json: {cid} spirit_cost 必须是非负数字")
            if "forbidden" in card and not isinstance(card["forbidden"], bool):
                err(f"data/talismans.json: {cid} forbidden 必须是 bool")
            if segment == "head" and not isinstance(card.get("effect"), dict):
                err(f"data/talismans.json: {cid}（符头）缺 effect 对象")
            if segment == "foot":
                timing = card.get("timing")
                if timing is not None and timing != "sentence_end":
                    err(f"data/talismans.json: {cid} timing 只能是 sentence_end")
                if not isinstance(card.get("action"), dict):
                    err(f"data/talismans.json: {cid}（符脚）缺 action 对象")
            if segment == "body" and not isinstance(card.get("damage", 0), (int, float)):
                err(f"data/talismans.json: {cid} damage 必须是数字")
            # C-ACT 动作校验（body.payloads / foot.action / phantom.effect）
            ops_src = []
            if segment == "body":
                ops_src = card.get("payloads", [])
            elif segment == "foot":
                ops_src = card.get("action")
            for action in _walk_actions(ops_src):
                op = action["op"]
                if op not in TALISMAN_OPS:
                    err(f"data/talismans.json: {cid} 未知动作 op {op}")
                    continue
                for field in TALISMAN_OP_REQUIRED[op]:
                    if field not in action:
                        err(f"data/talismans.json: {cid} 动作 {op} 缺字段 {field}")
                for mat in _action_material_refs(action):
                    if mat not in material_ids:
                        err(f"data/talismans.json: {cid} 动作 {op} 引用未定义物质 {mat}")

    phantoms = data.get("phantom_pool") or []
    if not isinstance(phantoms, list):
        err("data/talismans.json: phantom_pool 必须是数组")
        phantoms = []
    for p in phantoms:
        if not isinstance(p, dict) or not p.get("id"):
            err("data/talismans.json: phantom_pool 项缺 id")
            continue
        pid = p["id"]
        if pid in by_id:
            err(f"data/talismans.json: 重复 id {pid}")
        by_id[pid] = p
        segment_of[pid] = "phantom"
        if not isinstance(p.get("effect"), dict):
            err(f"data/talismans.json: {pid} 缺 effect")
            continue
        for action in _walk_actions(p["effect"]):
            op = action["op"]
            if op not in TALISMAN_OPS:
                err(f"data/talismans.json: {pid} 未知动作 op {op}")
            for mat in _action_material_refs(action):
                if mat not in material_ids:
                    err(f"data/talismans.json: {pid} 引用未定义物质 {mat}")

    groups = data.get("groups")
    if not isinstance(groups, list) or not groups:
        err("data/talismans.json: groups 必须是非空数组")
        groups = []
    group_ids = set()
    refs_cards = {}
    try:
        refs_data = load_yaml("refs/cards/p0/talismans.yaml") or []
        for card in refs_data:
            if isinstance(card, dict) and card.get("id"):
                refs_cards[card["id"]] = card
    except Exception:  # noqa: BLE001
        pass
    for g in groups:
        if not isinstance(g, dict) or not g.get("id"):
            err("data/talismans.json: groups 项缺 id")
            continue
        gid = g["id"]
        if gid in group_ids:
            err(f"data/talismans.json: 组 id 重复 {gid}")
        group_ids.add(gid)
        segs = g.get("segments")
        if not isinstance(segs, list) or not segs:
            err(f"data/talismans.json: 组 {gid} segments 必须非空")
            continue
        for sid in segs:
            if sid not in by_id:
                err(f"data/talismans.json: 组 {gid} 引用未定义卡 {sid}")
        total = 0.0
        saw_body = False
        for i, sid in enumerate(segs):
            seg = segment_of.get(sid)
            if i == 0:
                pass
            if seg == "head" and saw_body:
                err(f"data/talismans.json: 组 {gid} 符头必须都在符胆之前")
            if seg == "body":
                if saw_body:
                    err(f"data/talismans.json: 组 {gid} 一句只能有一个符胆")
                saw_body = True
            if seg == "phantom":
                err(f"data/talismans.json: 组 {gid} 不能引用幻符")
            total += by_id.get(sid, {}).get("spirit_cost", 0) if sid in by_id else 0
        if not saw_body:
            err(f"data/talismans.json: 组 {gid} 缺符胆")
        cost = g.get("spirit_cost")
        if not isinstance(cost, (int, float)):
            err(f"data/talismans.json: 组 {gid} 缺 spirit_cost")
        elif abs(cost - total) > 1e-9:
            err(f"data/talismans.json: 组 {gid} spirit_cost {cost} != 各段之和 {total}")
        if gid in refs_cards:
            ref_cost = (refs_cards[gid].get("numbers") or {}).get("spirit_cost")
            if isinstance(ref_cost, (int, float)) and isinstance(cost, (int, float)):
                if abs(ref_cost - cost) > 1e-9:
                    err(f"data/talismans.json: 组 {gid} spirit_cost {cost} 与 refs 卡面 {ref_cost} 不一致")

    # 与 T1 测试替身卡表交叉校验（防止正式数据与契约用例漂移）
    try:
        vm_cards = load_yaml("tests/vm_cases/cards.yaml") or {}
        vm_by_id = {}
        for section in ("head", "body", "foot"):
            for card in ((vm_cards.get("segments") or {}).get(section) or []):
                if isinstance(card, dict) and card.get("id"):
                    vm_by_id[card["id"]] = card
        for pid in vm_cards.get("phantom_pool") or []:
            if isinstance(pid, dict) and pid.get("id"):
                vm_by_id[pid["id"]] = pid
        for cid, card in by_id.items():
            other = vm_by_id.get(cid)
            if other is None:
                continue
            for field in ("spirit_cost", "forbidden", "element", "damage", "damage_type"):
                if field in other and card.get(field) != other.get(field):
                    err(f"data/talismans.json: {cid}.{field} 与 tests/vm_cases/cards.yaml 不一致（{card.get(field)!r} != {other.get(field)!r}）")
    except Exception:  # noqa: BLE001
        pass

    print(f"talismans: {len(by_id)} 卡 | {len(groups)} 组")
    return set(by_id.keys())


def validate_texts(material_by_id, reaction_ids, talisman_ids):
    """校验 C-TEXT v0.1 词表（data/texts/zh-CN.json）：键格式、D3 corruptible 硬约束、与 data 交叉引用。"""
    rel = "data/texts/zh-CN.json"
    p = ROOT / rel
    if not p.exists():
        err(f"{rel}: 文件不存在（C-TEXT v0.1 必填）")
        return
    data = load_json(rel)
    if data is None:
        return
    for field in ("schema", "version", "locale"):
        if not data.get(field):
            err(f"{rel}: 缺少 {field}")
    entries = data.get("entries")
    if not isinstance(entries, dict) or not entries:
        err(f"{rel}: entries 必须是非空对象")
        return

    for key, item in entries.items():
        if not isinstance(key, str) or not TEXT_KEY_RE.match(key):
            err(f"{rel}: 非法文本键格式 {key!r}")
            continue
        if not isinstance(item, dict):
            err(f"{rel}: {key} 必须是对象")
            continue
        text = item.get("text")
        if not isinstance(text, str) or not text.strip():
            err(f"{rel}: {key} 缺少非空 text")
        corruptible = item.get("corruptible")
        if not isinstance(corruptible, bool):
            err(f"{rel}: {key} 缺少 bool 类型 corruptible")
            continue
        if any(key.startswith(pref) for pref in NON_CORRUPTIBLE_PREFIXES) and corruptible:
            err(f"{rel}: {key} 违反 D3 红线（已知/规则域 corruptible 必须为 false）")
        if corruptible:
            corrupted = item.get("corrupted")
            if not isinstance(corrupted, str) or not corrupted.strip():
                err(f"{rel}: {key} corruptible=true 时必须提供非空 corrupted 文本")

    # 交叉校验：materials.ui_key / reactions / talismans
    for mid, m in material_by_id.items():
        uk = m.get("ui_key")
        if isinstance(uk, str) and uk and uk not in entries:
            err(f"{rel}: 缺少物质 {mid} 的 ui_key {uk}")
    for rid in reaction_ids:
        rk = "$react_" + rid.removeprefix("r-").replace("-", "_")
        if rk not in entries:
            err(f"{rel}: 缺少反应 {rid} 的文本键 {rk}")
    for cid in talisman_ids:
        ck = "$card_" + cid.replace("-", "_")
        if ck not in entries:
            err(f"{rel}: 缺少符卡 {cid} 的文本键 {ck}")

    print(f"texts: {len(entries)} 条（C-TEXT v0.1）")
    return set(entries.keys())


def validate_entities(material_ids, talisman_ids, text_keys):
    """M1-06 敌人数据校验：检查 data/entities/*.json 的血量、标签、文本键、掉落引用及与 biome 实体对齐。"""
    ent_dir = ROOT / "data" / "entities"
    if not ent_dir.exists():
        return set()
    seen = set()
    valid_tiers = {"mob", "elite", "boss"}
    valid_moves = {"ground", "fly", "boss"}
    for p in sorted(ent_dir.glob("*.json")):
        rel = str(p.relative_to(ROOT))
        data = load_json(rel)
        if data is None:
            continue
        if data.get("schema") != "gamev0.entities/v0.1":
            err(f"{rel}: schema 应为 gamev0.entities/v0.1")
        ents = data.get("entities")
        if not isinstance(ents, list) or not ents:
            err(f"{rel}: entities 必须是非空数组")
            continue
        for i, e in enumerate(ents):
            if not isinstance(e, dict):
                err(f"{rel}: entities[{i}] 不是对象")
                continue
            eid = e.get("id")
            if not isinstance(eid, str) or not eid:
                err(f"{rel}: entities[{i}] 缺少 id")
                continue
            if eid in seen:
                err(f"{rel}: 重复实体 id {eid}")
            seen.add(eid)
            nk = e.get("name_key")
            if not isinstance(nk, str) or nk not in text_keys:
                err(f"{rel}.{eid}: name_key {nk!r} 不在 C-TEXT 词表中")
            if e.get("tier") not in valid_tiers:
                err(f"{rel}.{eid}: tier 非法: {e.get('tier')!r}")
            if e.get("move_mode") not in valid_moves:
                err(f"{rel}.{eid}: move_mode 非法: {e.get('move_mode')!r}")
            for nf in ("hp", "damage", "half_w", "height"):
                v = e.get(nf)
                if not isinstance(v, (int, float)) or isinstance(v, bool) or v <= 0:
                    err(f"{rel}.{eid}: {nf} 必须是正数")
            drop = e.get("drop") or {}
            if isinstance(drop, dict):
                for dm in drop.get("materials", []):
                    if dm not in material_ids:
                        err(f"{rel}.{eid}: drop.materials 引用了未定义物质 {dm!r}")
                dt = drop.get("talisman")
                if dt is not None and dt not in talisman_ids:
                    err(f"{rel}.{eid}: drop.talisman 引用了未定义符卡 {dt!r}")
        # 交叉校验所属 biome 的 spawn_table 实体全部覆盖
        biome_id = data.get("biome_id")
        if isinstance(biome_id, str) and biome_id:
            bp = ROOT / "data" / "biomes" / f"{biome_id}.json"
            if bp.exists():
                bdata = load_json(str(bp.relative_to(ROOT))) or {}
                st = bdata.get("spawn_table") or {}
                for grp in ("mobs", "elites"):
                    for item in st.get(grp, []) or []:
                        ref_e = item.get("entity") if isinstance(item, dict) else None
                        if ref_e and ref_e not in seen:
                            err(f"{rel}: 未覆盖 biome {biome_id} 引用的实体 {ref_e}")
                boss = st.get("boss")
                if isinstance(boss, dict) and boss.get("entity") and boss["entity"] not in seen:
                    err(f"{rel}: 未覆盖 biome {biome_id} 引用的 BOSS 实体 {boss['entity']}")
    print(f"entities: {len(seen)} 种敌人")
    return seen


def validate_wands(talisman_ids):
    """M1-03 法器数据校验：检查 data/wands.json 的 3 把法器参数与 default_deck / starter_bag 符卡引用。"""
    rel = "data/wands.json"
    if not (ROOT / rel).exists():
        warnings.append(f"{rel}: 文件不存在，跳过法器校验")
        return set()
    data = load_json(rel)
    if data is None:
        return set()
    if data.get("schema") != "gamev0.wands/v0.1":
        err(f"{rel}: schema 应为 gamev0.wands/v0.1")
    wands = data.get("wands")
    if not isinstance(wands, list) or not wands:
        err(f"{rel}: wands 必须是非空数组")
        return set()
    seen = set()
    for i, w in enumerate(wands):
        if not isinstance(w, dict):
            err(f"{rel}: wands[{i}] 不是对象")
            continue
        wid = w.get("id")
        if not isinstance(wid, str) or not wid:
            err(f"{rel}: wands[{i}] 缺少 id")
            continue
        if wid in seen:
            err(f"{rel}: 重复法器 id {wid}")
        seen.add(wid)
        slots = w.get("slots")
        if not isinstance(slots, int) or isinstance(slots, bool) or slots <= 0:
            err(f"{rel}.{wid}: slots 必须是正整数")
        if not isinstance(w.get("ordered"), bool):
            err(f"{rel}.{wid}: ordered 必须是布尔值")
        for num_field in ("spirit_max", "regen_per_sec", "sentences_per_cast", "recharge_ticks", "price"):
            val = w.get(num_field)
            if not isinstance(val, (int, float)) or isinstance(val, bool) or val <= 0:
                err(f"{rel}.{wid}: {num_field} 必须是正数")
        deck = w.get("default_deck", [])
        if not isinstance(deck, list):
            err(f"{rel}.{wid}: default_deck 必须是数组")
        else:
            if isinstance(slots, int) and len(deck) > slots:
                err(f"{rel}.{wid}: default_deck 长度 {len(deck)} 超过 slots {slots}")
            for cid in deck:
                if cid and cid not in talisman_ids:
                    err(f"{rel}.{wid}: default_deck 引用了未定义符卡 {cid}")
    bag = data.get("starter_bag", [])
    if isinstance(bag, list):
        for cid in bag:
            if cid not in talisman_ids:
                err(f"{rel}: starter_bag 引用了未定义符卡 {cid}")
    print(f"wands: {len(seen)} 把法器")
    return seen


def validate_vm_cases():
    """C-VM 用例守护（T1）：调用 tests/vm_cases/validate_cases.py 做结构 / 算术 / 不变量自检。

    用例是 T1 的契约产物，T3 按它实现参考 VM；把它纳入 T0 校验，CI 就能在用例被改坏时变红
    （无需 workflow 权限）。用例不存在时只记 warning，不阻塞不涉及 VM 的破坏性测试。
    """
    script = ROOT / "tests" / "vm_cases" / "validate_cases.py"
    if not script.exists():
        warnings.append("tests/vm_cases/validate_cases.py 不存在，跳过 C-VM 用例校验")
        return
    proc = subprocess.run(
        [sys.executable, str(script), str(ROOT)],
        capture_output=True, text=True, cwd=str(ROOT),
    )
    if proc.returncode != 0:
        tail = (proc.stdout + proc.stderr).strip().splitlines()[-8:]
        err("tests/vm_cases: 用例自检失败（退出码 %d）: %s" % (proc.returncode, " | ".join(tail)))
    else:
        last = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
        print("vm_cases: " + (last or "自检通过"))


def main():
    material_ids, reaction_ids, material_by_id = validate_materials()
    validate_magic_numbers()
    room_map = load_rooms(material_ids, material_by_id)
    validate_biomes(room_map, material_by_id, material_ids, reaction_ids)
    validate_cards()
    talisman_ids = validate_talismans(material_ids) or set()
    validate_wands(talisman_ids)
    text_keys = validate_texts(material_by_id, reaction_ids, talisman_ids) or set()
    validate_entities(material_ids, talisman_ids, text_keys)
    validate_vm_cases()

    print(f"materials: {len(material_ids)} | reactions: {len(reaction_ids)} | rooms: {len(room_map)}")
    for w in warnings:
        print(f"WARN: {w}")
    if errors:
        print(f"\nFAIL: {len(errors)} 个错误", file=sys.stderr)
        for e in errors:
            print(f" - {e}", file=sys.stderr)
        return 1
    print("OK: 数据与卡片校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
