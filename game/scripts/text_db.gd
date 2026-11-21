extends RefCounted
## C-TEXT v0.1 文本键读取器（M1-01 冻结契约，见 docs/tech/m1-01-contracts-evt-text.md Part 2）。
## 从 data/texts/zh-CN.json 读取全部玩家可见文本，并按 D3 规则在 sanity < 66 时仅对
## corruptible=true 的未知条目返回 corrupted 文本（已学符名/物质/反应永不腐坏）。

const DEFAULT_PATH := "../data/texts/zh-CN.json"
const SANITY_CORRUPT_THRESHOLD := 66

var _entries: Dictionary = {}
var _loaded := false
var _locale := ""

func load_locale(rel_path: String = DEFAULT_PATH) -> bool:
	_entries.clear()
	_loaded = false
	var path := ProjectSettings.globalize_path("res://").path_join(rel_path)
	if not FileAccess.file_exists(path):
		push_error("C-TEXT: 找不到词表文件 " + path)
		return false
	var raw := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_error("C-TEXT: JSON 解析失败 " + path)
		return false
	var root_dict: Dictionary = parsed
	var entries: Variant = root_dict.get("entries")
	if not (entries is Dictionary):
		push_error("C-TEXT: 缺少 entries 对象 " + path)
		return false
	_entries = entries
	_locale = String(root_dict.get("locale", "zh-CN"))
	_loaded = true
	return true

func is_loaded() -> bool:
	return _loaded

func entry_count() -> int:
	return _entries.size()

func has_key(key: String) -> bool:
	return _entries.has(key)

## 查询文本键；当 sanity < 66 且该条目 corruptible == true 时返回 corrupted 文本。
func get_text(key: String, sanity: int = 100) -> String:
	if not _entries.has(key):
		return key
	var item: Variant = _entries[key]
	if not (item is Dictionary):
		return key
	var d: Dictionary = item
	if sanity < SANITY_CORRUPT_THRESHOLD and bool(d.get("corruptible", false)):
		var corr := String(d.get("corrupted", ""))
		if not corr.is_empty():
			return corr
	return String(d.get("text", key))

## 按卡片 id 列表动态拼接符句展示名（如 ["body-flying-sword", "foot-sha"] -> "斩 + 爆"），不另起合体名。
func compose_cards(card_ids: Array, sep: String = " + ") -> String:
	var parts: PackedStringArray = []
	for raw_id in card_ids:
		var cid := String(raw_id)
		var key := "$card_" + cid.replace("-", "_")
		parts.append(get_text(key, 100))
	return sep.join(parts)
