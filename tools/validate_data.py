#!/usr/bin/env python3
"""gameV0 数据与卡片校验器（T0）。

用法：
    python3 tools/validate_data.py            # 校验仓库根目录
    python3 tools/validate_data.py <root>     # 校验指定目录（用于破坏性测试）

规则来源：docs/02-m0-plan.md T0。
退出码：0 全过；1 有错误；2 缺依赖。
"""
import json
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
