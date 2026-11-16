#include "card_data.h"

#include <cmath>
#include <utility>

#include "json_lite.h"

namespace gdsim {
namespace {

vm::Value to_vm_value(const simcore::json::Value &p_value) {
    switch (p_value.type) {
        case simcore::json::Value::NUL:
            return vm::Value::make_null();
        case simcore::json::Value::BOOL:
            return vm::Value::make_bool(p_value.boolean);
        case simcore::json::Value::NUMBER:
            return vm::Value::make_number(p_value.number);
        case simcore::json::Value::STRING:
            return vm::Value::make_string(p_value.str);
        case simcore::json::Value::ARRAY: {
            std::vector<vm::Value> items;
            items.reserve(p_value.arr.size());
            for (const simcore::json::Value &item : p_value.arr) {
                items.push_back(to_vm_value(item));
            }
            return vm::Value::make_array(std::move(items));
        }
        case simcore::json::Value::OBJECT: {
            std::vector<std::pair<std::string, vm::Value>> members;
            members.reserve(p_value.obj.size());
            for (const auto &member : p_value.obj) {
                members.emplace_back(member.first, to_vm_value(member.second));
            }
            return vm::Value::make_object(std::move(members));
        }
    }
    return vm::Value::make_null();
}

double number_field(const simcore::json::Value &p_object, const char *p_key, double p_default) {
    const simcore::json::Value *value = p_object.find(p_key);
    return (value != nullptr && value->is_number()) ? value->number : p_default;
}

std::string string_field(const simcore::json::Value &p_object, const char *p_key) {
    const simcore::json::Value *value = p_object.find(p_key);
    return (value != nullptr && value->is_string()) ? value->str : std::string();
}

bool bool_field(const simcore::json::Value &p_object, const char *p_key) {
    const simcore::json::Value *value = p_object.find(p_key);
    return value != nullptr && value->is_bool() && value->boolean;
}

bool load_card_section(const simcore::json::Value &p_root, const char *p_section,
                       vm::CardSegment p_segment, vm::CardCatalog *r_catalog, std::string *r_error) {
    const simcore::json::Value *cards = p_root.find("cards");
    if (cards == nullptr || !cards->is_object()) {
        *r_error = "talismans.json: 缺 cards 对象";
        return false;
    }
    const simcore::json::Value *section = cards->find(p_section);
    if (section == nullptr || !section->is_array()) {
        *r_error = std::string("talismans.json: cards.") + p_section + " 必须是数组";
        return false;
    }
    for (const simcore::json::Value &raw : section->arr) {
        if (!raw.is_object()) {
            *r_error = std::string("talismans.json: cards.") + p_section + " 项不是对象";
            return false;
        }
        vm::Card card;
        card.id = string_field(raw, "id");
        if (card.id.empty()) {
            *r_error = std::string("talismans.json: cards.") + p_section + " 项缺 id";
            return false;
        }
        card.segment = p_segment;
        card.spirit_cost = number_field(raw, "spirit_cost", 0.0);
        card.forbidden = bool_field(raw, "forbidden");
        card.timing = string_field(raw, "timing");
        card.element = string_field(raw, "element");
        card.damage_type = string_field(raw, "damage_type");
        card.damage = number_field(raw, "damage", 0.0);
        card.pierce = static_cast<int>(number_field(raw, "pierce", 0.0));
        const simcore::json::Value *payloads = raw.find("payloads");
        card.payloads = (payloads != nullptr) ? to_vm_value(*payloads) : vm::Value::make_array();
        const simcore::json::Value *action = raw.find("action");
        card.action = (action != nullptr) ? to_vm_value(*action) : vm::Value::make_null();
        const simcore::json::Value *effect = raw.find("effect");
        card.effect = (effect != nullptr) ? to_vm_value(*effect) : vm::Value::make_null();
        r_catalog->cards.push_back(std::move(card));
    }
    return true;
}

}  // namespace

const GroupDef *CardData::find_group(const std::string &p_id) const {
    for (const GroupDef &group : groups) {
        if (group.id == p_id) {
            return &group;
        }
    }
    return nullptr;
}

bool load_card_data(const std::string &p_path, CardData *r_data, std::string *r_error) {
    r_data->catalog.cards.clear();
    r_data->groups.clear();
    r_data->loaded = false;
    simcore::json::Value root;
    std::string parse_error;
    if (!simcore::json::parse_file(p_path, &root, &parse_error)) {
        *r_error = "读 " + p_path + " 失败: " + parse_error;
        return false;
    }
    if (!root.is_object()) {
        *r_error = "talismans.json: 顶层必须是对象";
        return false;
    }
    if (!load_card_section(root, "heads", vm::CardSegment::kHead, &r_data->catalog, r_error)) {
        return false;
    }
    if (!load_card_section(root, "bodies", vm::CardSegment::kBody, &r_data->catalog, r_error)) {
        return false;
    }
    if (!load_card_section(root, "feet", vm::CardSegment::kFoot, &r_data->catalog, r_error)) {
        return false;
    }
    // 幻符（可选）
    const simcore::json::Value *cards = root.find("cards");
    (void)cards;
    const simcore::json::Value *phantoms = root.find("phantom_pool");
    if (phantoms != nullptr && phantoms->is_array()) {
        for (const simcore::json::Value &raw : phantoms->arr) {
            if (!raw.is_object()) {
                *r_error = "talismans.json: phantom_pool 项不是对象";
                return false;
            }
            vm::Card card;
            card.id = string_field(raw, "id");
            if (card.id.empty()) {
                *r_error = "talismans.json: phantom_pool 项缺 id";
                return false;
            }
            card.segment = vm::CardSegment::kPhantom;
            const simcore::json::Value *effect = raw.find("effect");
            card.effect = (effect != nullptr) ? to_vm_value(*effect) : vm::Value::make_null();
            r_data->catalog.cards.push_back(std::move(card));
        }
    }

    // 法器默认值（可选）
    const simcore::json::Value *wand = root.find("wand_defaults");
    if (wand != nullptr && wand->is_object()) {
        r_data->wand.spirit = number_field(*wand, "spirit", r_data->wand.spirit);
        r_data->wand.spirit_max = number_field(*wand, "spirit_max", r_data->wand.spirit_max);
        r_data->wand.regen_per_sec = number_field(*wand, "regen_per_sec", r_data->wand.regen_per_sec);
        r_data->wand.slots = static_cast<int>(number_field(*wand, "slots", r_data->wand.slots));
        r_data->wand.sentences_per_cast = static_cast<int>(
            number_field(*wand, "sentences_per_cast", r_data->wand.sentences_per_cast));
        r_data->wand.recharge_ticks = static_cast<int>(
            number_field(*wand, "recharge_ticks", r_data->wand.recharge_ticks));
    }

    // 符组
    const simcore::json::Value *groups = root.find("groups");
    if (groups == nullptr || !groups->is_array() || groups->arr.empty()) {
        *r_error = "talismans.json: groups 必须是非空数组";
        return false;
    }
    for (const simcore::json::Value &raw : groups->arr) {
        if (!raw.is_object()) {
            *r_error = "talismans.json: groups 项不是对象";
            return false;
        }
        GroupDef group;
        group.id = string_field(raw, "id");
        group.name = string_field(raw, "name");
        group.spirit_cost = number_field(raw, "spirit_cost", 0.0);
        const simcore::json::Value *segments = raw.find("segments");
        if (group.id.empty() || segments == nullptr || !segments->is_array() || segments->arr.empty()) {
            *r_error = "talismans.json: groups 项缺 id 或 segments";
            return false;
        }
        for (const simcore::json::Value &segment : segments->arr) {
            if (!segment.is_string()) {
                *r_error = "talismans.json: groups.segments 必须是字符串数组";
                return false;
            }
            if (r_data->catalog.find(segment.str) == nullptr) {
                *r_error = "talismans.json: 组 " + group.id + " 引用未定义卡 " + segment.str;
                return false;
            }
            group.segments.push_back(segment.str);
        }
        r_data->groups.push_back(std::move(group));
    }

    r_data->loaded = true;
    return true;
}

}  // namespace gdsim
