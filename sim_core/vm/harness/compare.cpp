#include "compare.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

#include "json_util.h"

namespace vmtest {
namespace {

using vm::Value;

std::string type_name(Value::Type type) {
    switch (type) {
        case Value::Type::kNull:
            return "null";
        case Value::Type::kBool:
            return "bool";
        case Value::Type::kNumber:
            return "number";
        case Value::Type::kString:
            return "string";
        case Value::Type::kArray:
            return "array";
        case Value::Type::kObject:
            return "object";
    }
    return "unknown";
}

std::string trim(const std::string& text) {
    std::size_t begin = 0;
    while (begin < text.size() && (text[begin] == ' ' || text[begin] == '\t')) ++begin;
    std::size_t end = text.size();
    while (end > begin && (text[end - 1] == ' ' || text[end - 1] == '\t')) --end;
    return text.substr(begin, end - begin);
}

// 数值相等：允许 1e-9 相对误差。YAML 十进制字面量与 C++ double 乘法
// （如 8×1.2、15×1.2）可能差 1 ulp；这仍是同一个数，不改变 §6.3 "深度相等" 的语义。
bool numbers_equal(double expected, double actual) {
    const double scale = std::max({1.0, std::fabs(expected), std::fabs(actual)});
    return std::fabs(expected - actual) <= 1e-9 * scale;
}

std::string format_number(double number) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.15g", number);
    return std::string(buffer);
}

// ---------------------------------------------------------------------------
// 动作规范化（§3.1：按 §3.2 默认值补齐字段后再比较；from 不比较）
// ---------------------------------------------------------------------------
Value normalize_trigger(const Value& raw);
Value normalize_action(const Value& raw);

std::vector<std::pair<std::string, Value>> action_defaults(const std::string& op) {
    std::vector<std::pair<std::string, Value>> fields;
    auto add = [&fields](const char* key, Value value) { fields.emplace_back(key, std::move(value)); };
    // 必填字段的占位默认值是 null（缺字段时比较会因类型不同而失败）。
    if (op == "spawn_projectile") {
        add("spell", Value::make_null());
        add("count", Value::make_number(1));
        add("damage", Value::make_number(0));
        add("damage_type", Value::make_string("none"));
        add("element", Value::make_string("none"));
        add("pierce", Value::make_number(0));
        add("speed", Value::make_number(12));
        add("spread_deg", Value::make_number(0));
        add("ttl_ticks", Value::make_number(120));
        add("payloads", Value::make_array());
        add("trigger", Value::make_null());
    } else if (op == "explode") {
        add("radius", Value::make_null());
        add("damage", Value::make_null());
        add("damage_type", Value::make_null());
    } else if (op == "damage") {
        add("amount", Value::make_null());
        add("damage_type", Value::make_null());
        add("radius", Value::make_number(0));
    } else if (op == "ignite") {
        add("duration", Value::make_null());
        add("spread", Value::make_bool(false));
        add("damage_per_sec", Value::make_number(0));
        add("produces", Value::make_null());
        add("target_tags", Value::make_array());
    } else if (op == "spawn_cloud") {
        add("kind", Value::make_null());
        add("radius", Value::make_null());
        add("duration", Value::make_null());
        add("damage", Value::make_number(0));
        add("damage_per_sec", Value::make_number(0));
        add("damage_type", Value::make_string("none"));
        add("tags", Value::make_array());
    } else if (op == "purify") {
        add("removes", Value::make_null());
        add("radius", Value::make_number(3));
    } else if (op == "barrier") {
        add("effect", Value::make_null());
        add("radius", Value::make_number(1));
        add("duration", Value::make_number(0));
    } else if (op == "grant_temp_slot") {
        add("value", Value::make_number(1));
        add("duration", Value::make_number(60));
    } else if (op == "convert_material") {
        add("source", Value::make_null());
        add("to", Value::make_null());
        add("radius", Value::make_number(1));
    } else if (op == "spawn_material") {
        add("material", Value::make_null());
        add("shape", Value::make_null());
        add("count", Value::make_number(1));
        add("radius", Value::make_number(1));
        add("duration", Value::make_number(0));
    } else if (op == "dig") {
        add("radius", Value::make_null());
        add("mode", Value::make_string("remove_solid"));
    } else if (op == "apply_status") {
        add("status", Value::make_null());
        add("duration", Value::make_null());
    } else if (op == "extinguish_lantern") {
        add("lanterns", Value::make_null());
    } else if (op == "drain_life") {
        add("amount", Value::make_null());
    } else if (op == "refund_spirit") {
        add("amount", Value::make_null());
    } else if (op == "phantom_cast") {
        add("spell", Value::make_null());
        add("reason", Value::make_null());
        add("effect", Value::make_null());
        add("payloads", Value::make_array());
    }
    return fields;
}

Value normalize_field_value(const std::string& key, const Value& value) {
    if (key == "payloads" && value.is_array()) {
        std::vector<Value> items;
        items.reserve(value.items().size());
        for (const Value& item : value.items()) items.push_back(normalize_action(item));
        return Value::make_array(std::move(items));
    }
    if (key == "trigger" && value.is_object()) return normalize_trigger(value);
    if (key == "effect" && value.is_object()) return normalize_action(value);
    return value;
}

Value normalize_action(const Value& raw) {
    if (!raw.is_object()) return raw;
    const Value* op_value = raw.find("op");
    const std::string op = (op_value != nullptr && op_value->is_string()) ? op_value->as_string() : std::string();
    const std::vector<std::pair<std::string, Value>> defaults = action_defaults(op);
    Value normalized = Value::make_object();
    normalized.set("op", Value::make_string(op));
    for (const auto& field : defaults) {
        const Value* provided = raw.find(field.first);
        const Value value = (provided != nullptr) ? *provided : field.second;
        normalized.set(field.first, normalize_field_value(field.first, value));
    }
    // 未知字段原样保留 → 对象字段集合不同会在比较时暴露（§6.3 字段集合相同）。
    for (const auto& member : raw.members()) {
        if (member.first == "from" || member.first == "op") continue;  // §3.1：from 不参与比较
        if (normalized.has(member.first)) continue;
        normalized.set(member.first, member.second);
    }
    return normalized;
}

Value normalize_trigger(const Value& raw) {
    if (!raw.is_object()) return raw;
    Value normalized = Value::make_object();
    const Value* kind = raw.find("kind");
    normalized.set("kind", kind != nullptr ? *kind : Value::make_null());
    const Value* depth = raw.find("depth");
    normalized.set("depth", depth != nullptr ? *depth : Value::make_null());
    std::vector<Value> actions;
    const Value* raw_actions = raw.find("actions");
    if (raw_actions != nullptr && raw_actions->is_array()) {
        for (const Value& action : raw_actions->items()) actions.push_back(normalize_action(action));
    }
    normalized.set("actions", Value::make_array(std::move(actions)));
    for (const auto& member : raw.members()) {
        if (normalized.has(member.first)) continue;
        normalized.set(member.first, member.second);
    }
    return normalized;
}

// ---------------------------------------------------------------------------
// 深度比较
// ---------------------------------------------------------------------------
bool compare_values(const Value& expected, const Value& actual, const std::string& path,
                    std::vector<std::string>* errors) {
    if (expected.type() != actual.type()) {
        errors->push_back(path + ": 类型不同（期望 " + type_name(expected.type()) + " = " + dump_value(expected) +
                          "，实际 " + type_name(actual.type()) + " = " + dump_value(actual) + "）");
        return false;
    }
    switch (expected.type()) {
        case Value::Type::kNull:
            return true;
        case Value::Type::kBool:
            if (expected.as_bool() != actual.as_bool()) {
                errors->push_back(path + ": 期望 " + dump_value(expected) + "，实际 " + dump_value(actual));
                return false;
            }
            return true;
        case Value::Type::kNumber:
            if (!numbers_equal(expected.as_number(), actual.as_number())) {
                errors->push_back(path + ": 期望 " + dump_value(expected) + "，实际 " + dump_value(actual));
                return false;
            }
            return true;
        case Value::Type::kString:
            if (expected.as_string() != actual.as_string()) {
                errors->push_back(path + ": 期望 " + dump_value(expected) + "，实际 " + dump_value(actual));
                return false;
            }
            return true;
        case Value::Type::kArray: {
            if (expected.items().size() != actual.items().size()) {
                errors->push_back(path + ": 数组长度不同（期望 " + std::to_string(expected.items().size()) +
                                  "，实际 " + std::to_string(actual.items().size()) + "）");
                return false;
            }
            bool ok = true;
            for (std::size_t index = 0; index < expected.items().size(); ++index) {
                const std::string item_path = path + "[" + std::to_string(index) + "]";
                if (!compare_values(expected.items()[index], actual.items()[index], item_path, errors)) ok = false;
            }
            return ok;
        }
        case Value::Type::kObject: {
            bool ok = true;
            for (const auto& member : expected.members()) {
                const Value* other = actual.find(member.first);
                if (other == nullptr) {
                    errors->push_back(path + "." + member.first + ": 实际动作缺字段");
                    ok = false;
                    continue;
                }
                const std::string member_path = path + "." + member.first;
                if (!compare_values(member.second, *other, member_path, errors)) ok = false;
            }
            for (const auto& member : actual.members()) {
                if (expected.find(member.first) == nullptr) {
                    errors->push_back(path + "." + member.first + ": 实际动作多出字段");
                    ok = false;
                }
            }
            return ok;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 不变量表达式（§6.3 第 4 条）
// ---------------------------------------------------------------------------
struct InvariantValues {
    bool accepted = false;
    long action_count = 0;
    long spawn_count = 0;
    long max_depth = 0;
    double spirit_after = 0.0;
    long sanity_after = 0;
    long cursor_after = 0;
    long ready_at_tick_after = 0;
    bool round_ended = false;
    bool backlash_after = false;
    std::vector<int> phantom_slots_after;
    long consumed_count = 0;
};

InvariantValues values_from(const vm::CastResult& result) {
    InvariantValues values;
    values.accepted = result.accepted;
    values.action_count = result.action_count;
    values.spawn_count = result.spawn_count;
    values.max_depth = result.max_depth;
    values.spirit_after = result.spirit_after;
    values.sanity_after = result.sanity_after;
    values.cursor_after = result.cursor_after;
    values.ready_at_tick_after = result.ready_at_tick_after;
    values.round_ended = result.round_ended;
    values.backlash_after = result.backlash_after;
    values.phantom_slots_after = result.phantom_slots_after;
    values.consumed_count = static_cast<long>(result.consumed.size());
    return values;
}

Value value_of_lhs(const std::string& lhs, const InvariantValues& values) {
    if (lhs == "accepted") return Value::make_bool(values.accepted);
    if (lhs == "action_count") return Value::make_number(static_cast<double>(values.action_count));
    if (lhs == "spawn_count") return Value::make_number(static_cast<double>(values.spawn_count));
    if (lhs == "max_depth") return Value::make_number(static_cast<double>(values.max_depth));
    if (lhs == "spirit_after") return Value::make_number(values.spirit_after);
    if (lhs == "sanity_after") return Value::make_number(static_cast<double>(values.sanity_after));
    if (lhs == "cursor_after") return Value::make_number(static_cast<double>(values.cursor_after));
    if (lhs == "ready_at_tick_after") return Value::make_number(static_cast<double>(values.ready_at_tick_after));
    if (lhs == "round_ended") return Value::make_bool(values.round_ended);
    if (lhs == "backlash_after") return Value::make_bool(values.backlash_after);
    if (lhs == "consumed_count") return Value::make_number(static_cast<double>(values.consumed_count));
    if (lhs == "phantom_slots_after") {
        std::vector<Value> slots;
        slots.reserve(values.phantom_slots_after.size());
        for (int slot : values.phantom_slots_after) slots.push_back(Value::make_number(static_cast<double>(slot)));
        return Value::make_array(std::move(slots));
    }
    return Value::make_null();  // 未知左值
}

bool parse_invariant(const std::string& text, std::string* lhs, std::string* op, std::string* rhs) {
    const std::string trimmed = trim(text);
    std::size_t position = std::string::npos;
    std::string found;
    for (std::size_t index = 0; index < trimmed.size(); ++index) {
        if (index + 1 < trimmed.size()) {
            const std::string two = trimmed.substr(index, 2);
            if (two == "==" || two == "!=" || two == "<=" || two == ">=") {
                position = index;
                found = two;
                break;
            }
        }
        if (trimmed[index] == '<' || trimmed[index] == '>') {
            position = index;
            found = std::string(1, trimmed[index]);
            break;
        }
    }
    if (position == std::string::npos) return false;
    *lhs = trim(trimmed.substr(0, position));
    *op = found;
    *rhs = trim(trimmed.substr(position + found.size()));
    return !lhs->empty() && !rhs->empty();
}

Value parse_literal(const std::string& text, bool* ok) {
    const std::string trimmed = trim(text);
    *ok = true;
    if (trimmed == "true") return Value::make_bool(true);
    if (trimmed == "false") return Value::make_bool(false);
    if (trimmed == "null") return Value::make_null();
    if (!trimmed.empty() && trimmed.front() == '[') {
        if (trimmed.size() < 2 || trimmed.back() != ']') {
            *ok = false;
            return Value::make_null();
        }
        std::vector<Value> items;
        const std::string inner = trim(trimmed.substr(1, trimmed.size() - 2));
        if (!inner.empty()) {
            std::size_t begin = 0;
            while (true) {
                const std::size_t comma = inner.find(',', begin);
                const std::string piece = trim(comma == std::string::npos ? inner.substr(begin)
                                                                           : inner.substr(begin, comma - begin));
                char* end = nullptr;
                const double number = std::strtod(piece.c_str(), &end);
                if (end == piece.c_str() || *end != '\0') {
                    *ok = false;
                    return Value::make_null();
                }
                items.push_back(Value::make_number(number));
                if (comma == std::string::npos) break;
                begin = comma + 1;
            }
        }
        return Value::make_array(std::move(items));
    }
    char* end = nullptr;
    const double number = std::strtod(trimmed.c_str(), &end);
    if (end == trimmed.c_str() || *end != '\0') {
        *ok = false;
        return Value::make_null();
    }
    return Value::make_number(number);
}

bool values_equal(const Value& left, const Value& right) {
    if (left.is_array() && right.is_array()) {
        if (left.items().size() != right.items().size()) return false;
        for (std::size_t index = 0; index < left.items().size(); ++index) {
            if (!values_equal(left.items()[index], right.items()[index])) return false;
        }
        return true;
    }
    if (left.is_bool() && right.is_bool()) return left.as_bool() == right.as_bool();
    if (left.is_number() && right.is_number()) return numbers_equal(left.as_number(), right.as_number());
    if (left.is_string() && right.is_string()) return left.as_string() == right.as_string();
    return left.is_null() && right.is_null();
}

bool eval_compare(const Value& lhs, const std::string& op, const Value& rhs) {
    if (op == "==") return values_equal(lhs, rhs);
    if (op == "!=") return !values_equal(lhs, rhs);
    if (!lhs.is_number() || !rhs.is_number()) return false;
    if (op == "<") return lhs.as_number() < rhs.as_number();
    if (op == "<=") return lhs.as_number() <= rhs.as_number();
    if (op == ">") return lhs.as_number() > rhs.as_number();
    if (op == ">=") return lhs.as_number() >= rhs.as_number();
    return false;
}

bool has_event(const vm::CastResult& result, const std::string& code) {
    for (const vm::Event& event : result.events) {
        if (event.code == code) return true;
    }
    return false;
}

}  // namespace

std::string dump_value(const Value& value) {
    switch (value.type()) {
        case Value::Type::kNull:
            return "null";
        case Value::Type::kBool:
            return value.as_bool() ? "true" : "false";
        case Value::Type::kNumber:
            return format_number(value.as_number());
        case Value::Type::kString:
            return "\"" + value.as_string() + "\"";
        case Value::Type::kArray: {
            std::string text = "[";
            for (std::size_t index = 0; index < value.items().size(); ++index) {
                if (index != 0) text += ", ";
                text += dump_value(value.items()[index]);
            }
            text += "]";
            return text;
        }
        case Value::Type::kObject: {
            std::string text = "{";
            for (std::size_t index = 0; index < value.members().size(); ++index) {
                if (index != 0) text += ", ";
                text += value.members()[index].first + ": " + dump_value(value.members()[index].second);
            }
            text += "}";
            return text;
        }
    }
    return "?";
}

std::vector<std::string> compare_actions(const simcore::json::Value& expected_actions,
                                         const std::vector<Value>& actual_actions) {
    std::vector<std::string> errors;
    if (!expected_actions.is_array()) {
        errors.push_back("expect.actions 不是数组");
        return errors;
    }
    const Value expected_value = from_json(expected_actions);
    const std::vector<Value>& expected_items = expected_value.items();
    if (expected_items.size() != actual_actions.size()) {
        errors.push_back("actions: 动作数量不同（期望 " + std::to_string(expected_items.size()) + "，实际 " +
                         std::to_string(actual_actions.size()) + "）");
    }
    const std::size_t common = std::min(expected_items.size(), actual_actions.size());
    for (std::size_t index = 0; index < common; ++index) {
        const std::string path = "actions[" + std::to_string(index) + "]";
        const Value expected_action = normalize_action(expected_items[index]);
        const Value actual_action = normalize_action(actual_actions[index]);
        compare_values(expected_action, actual_action, path, &errors);
    }
    return errors;
}

std::vector<std::string> check_invariant_expressions(const simcore::json::Value& invariants,
                                                     const vm::CastResult& result) {
    std::vector<std::string> errors;
    if (!invariants.is_array()) {
        errors.push_back("expect.invariants 不是数组");
        return errors;
    }
    const InvariantValues values = values_from(result);
    for (const simcore::json::Value& raw : invariants.arr) {
        if (!raw.is_string()) {
            errors.push_back("invariants: 不是字符串: " + dump_value(from_json(raw)));
            continue;
        }
        std::string lhs;
        std::string op;
        std::string rhs;
        if (!parse_invariant(raw.str, &lhs, &op, &rhs)) {
            errors.push_back("invariants: 语法非法: \"" + raw.str + "\"");
            continue;
        }
        bool ok = false;
        const Value rhs_value = parse_literal(rhs, &ok);
        if (!ok) {
            errors.push_back("invariants: 右值无法解析: \"" + raw.str + "\"");
            continue;
        }
        const Value lhs_value = value_of_lhs(lhs, values);
        if (lhs_value.is_null()) {
            errors.push_back("invariants: 未知左值: \"" + raw.str + "\"");
            continue;
        }
        if (!eval_compare(lhs_value, op, rhs_value)) {
            errors.push_back("invariants: 不成立: \"" + raw.str + "\"（实际 " + dump_value(lhs_value) + "）");
        }
    }
    return errors;
}

std::vector<std::string> check_global_invariants(const vm::CastRequest& request, const vm::CastResult& result,
                                                 const vm::CardCatalog& catalog) {
    std::vector<std::string> errors;
    const bool backlash_consumed = has_event(result, "backlash_consumed");
    const bool phantom_substitute = has_event(result, "phantom_substitute");
    const bool forbidden_read = has_event(result, "forbidden_read");

    // I1 禁符与幻符永不同一次施法。
    if (backlash_consumed) {
        if (result.actions.size() != 1) {
            errors.push_back("I1: 反噬施法的动作列表应只有 1 个 phantom_cast");
        } else {
            const Value& action = result.actions.front();
            const Value* op = action.find("op");
            const Value* reason = action.find("reason");
            const bool is_phantom = op != nullptr && op->is_string() && op->as_string() == "phantom_cast";
            const bool is_backlash = reason != nullptr && reason->is_string() && reason->as_string() == "backlash";
            if (!is_phantom || !is_backlash) {
                errors.push_back("I1: 反噬施法动作应为 phantom_cast(reason=\"backlash\")，实际 " + dump_value(action));
            }
        }
        if (phantom_substitute) errors.push_back("I1: 反噬与 15% 幻符替换不能出现在同一次施法");
    }
    if (phantom_substitute) {
        if (forbidden_read) errors.push_back("I1: 替换施法解析树内不应含禁符");
        for (const std::string& id : result.consumed) {
            const vm::Card* card = catalog.find(id);
            if (card != nullptr && card->forbidden) {
                errors.push_back("I1: 替换施法解析树内不应含禁符（consumed 含 " + id + "）");
                break;
            }
        }
    }

    // I2 施法结束时 sanity < 33 ⇔ phantom_slots 非空（且最多 1 格）。
    const bool below_threshold = result.sanity_after < vm::kRechargingSanity;
    if (below_threshold == result.phantom_slots_after.empty()) {
        errors.push_back("I2: sanity_after < 33 与 phantom_slots_after 非空不等价（sanity=" +
                         std::to_string(result.sanity_after) + "，slots=" + dump_value([&result] {
                             std::vector<Value> slots;
                             for (int slot : result.phantom_slots_after) slots.push_back(Value::make_number(slot));
                             return Value::make_array(std::move(slots));
                         }()) + "）");
    }
    if (result.phantom_slots_after.size() > 1) errors.push_back("I2: 幻影符最多 1 格");
    if (result.sanity_after >= vm::kRechargingSanity && !result.phantom_slots_after.empty()) {
        errors.push_back("I2: sanity_after >= 33 时不应有幻影符");
    }

    // I3 反噬不会被"灵力不足"或"回符中"逃掉。
    if (request.state.backlash) {
        if (result.accepted) {
            if (!backlash_consumed) errors.push_back("I3: 初始反噬的施法必须消费反噬（backlash_consumed）");
        } else if (!result.backlash_after) {
            errors.push_back("I3: 回符中拒绝施法时反噬必须保留");
        }
    }

    // I4 反噬消费后 backlash_after = false。
    if (backlash_consumed && result.backlash_after) errors.push_back("I4: 反噬消费后 backlash_after 应为 false");

    // I5 15% 替换时 sanity 不变。
    if (phantom_substitute && result.sanity_after != request.state.sanity) {
        errors.push_back("I5: 15% 替换时 sanity 不应变化");
    }

    // I6 灵力/神智范围。
    if (result.spirit_after < -1e-9 || result.spirit_after > request.wand.spirit_max + 1e-9) {
        errors.push_back("I6: spirit_after 越界 [0, spirit_max]（" + format_number(result.spirit_after) + "）");
    }
    if (result.sanity_after < 0 || result.sanity_after > 100) {
        errors.push_back("I6: sanity_after 越界 [0, 100]");
    }
    return errors;
}

}  // namespace vmtest
