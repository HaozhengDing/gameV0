#include "vm_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cmath>
#include <string>

using namespace godot;

namespace {

Variant vm_value_to_variant(const vm::Value &p_value) {
    switch (p_value.type()) {
        case vm::Value::Type::kNull:
            return Variant();
        case vm::Value::Type::kBool:
            return p_value.as_bool();
        case vm::Value::Type::kNumber: {
            const double number = p_value.as_number();
            const double rounded = std::round(number);
            if (std::fabs(number - rounded) < 1e-9 && std::fabs(number) < 1e15) {
                return static_cast<int64_t>(rounded);
            }
            return number;
        }
        case vm::Value::Type::kString:
            return String::utf8(p_value.as_string().c_str());
        case vm::Value::Type::kArray: {
            Array array;
            for (const vm::Value &item : p_value.items()) {
                array.append(vm_value_to_variant(item));
            }
            return array;
        }
        case vm::Value::Type::kObject: {
            Dictionary dictionary;
            for (const auto &member : p_value.members()) {
                dictionary[String::utf8(member.first.c_str())] = vm_value_to_variant(member.second);
            }
            return dictionary;
        }
    }
    return Variant();
}

}  // namespace

void TalismanVMNode::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_cards", "path"), &TalismanVMNode::load_cards);
    ClassDB::bind_method(D_METHOD("is_loaded"), &TalismanVMNode::is_loaded);
    ClassDB::bind_method(D_METHOD("tick_advance"), &TalismanVMNode::tick_advance);
    ClassDB::bind_method(D_METHOD("reset"), &TalismanVMNode::reset);
    ClassDB::bind_method(D_METHOD("get_group_ids"), &TalismanVMNode::get_group_ids);
    ClassDB::bind_method(D_METHOD("get_groups"), &TalismanVMNode::get_groups);
    ClassDB::bind_method(D_METHOD("get_spirit"), &TalismanVMNode::get_spirit);
    ClassDB::bind_method(D_METHOD("get_spirit_max"), &TalismanVMNode::get_spirit_max);
    ClassDB::bind_method(D_METHOD("get_tick"), &TalismanVMNode::get_tick);
    ClassDB::bind_method(D_METHOD("get_ready_at_tick"), &TalismanVMNode::get_ready_at_tick);
    ClassDB::bind_method(D_METHOD("get_is_recharging"), &TalismanVMNode::get_is_recharging);
    ClassDB::bind_method(D_METHOD("cast_group", "group_id"), &TalismanVMNode::cast_group);
}

bool TalismanVMNode::load_cards(const String &p_path) {
    std::string error;
    CharString path_utf8 = p_path.utf8();
    if (!gdsim::load_card_data(path_utf8.get_data(), &data_, &error)) {
        ERR_PRINT(String("TalismanVMNode.load_cards: ") + String::utf8(error.c_str()));
        data_.loaded = false;
        return false;
    }
    reset();
    return true;
}

bool TalismanVMNode::is_loaded() const {
    return data_.loaded;
}

void TalismanVMNode::tick_advance() {
    ++tick_;
    if (data_.loaded) {
        spirit_ = std::fmin(data_.wand.spirit_max, spirit_ + data_.wand.regen_per_sec / 60.0);
    }
}

void TalismanVMNode::reset() {
    spirit_ = data_.loaded ? data_.wand.spirit : 0.0;
    tick_ = 0;
    ready_at_tick_ = 0;
}

Array TalismanVMNode::get_group_ids() const {
    Array ids;
    for (const gdsim::GroupDef &group : data_.groups) {
        ids.append(String::utf8(group.id.c_str()));
    }
    return ids;
}

Array TalismanVMNode::get_groups() const {
    Array groups;
    for (const gdsim::GroupDef &group : data_.groups) {
        Dictionary item;
        item["id"] = String::utf8(group.id.c_str());
        item["name"] = String::utf8(group.name.c_str());
        item["spirit_cost"] = group.spirit_cost;
        Array segments;
        for (const std::string &segment : group.segments) {
            segments.append(String::utf8(segment.c_str()));
        }
        item["segments"] = segments;
        groups.append(item);
    }
    return groups;
}

double TalismanVMNode::get_spirit() const {
    return spirit_;
}

double TalismanVMNode::get_spirit_max() const {
    return data_.loaded ? data_.wand.spirit_max : 0.0;
}

int64_t TalismanVMNode::get_tick() const {
    return tick_;
}

int64_t TalismanVMNode::get_ready_at_tick() const {
    return ready_at_tick_;
}

bool TalismanVMNode::get_is_recharging() const {
    return tick_ < ready_at_tick_;
}

Dictionary TalismanVMNode::cast_group(const String &p_group_id) {
    Dictionary out;
    if (!data_.loaded) {
        out["accepted"] = false;
        out["reject_reason"] = "no_cards";
        return out;
    }
    const gdsim::GroupDef *group = data_.find_group(p_group_id.utf8().get_data());
    if (group == nullptr) {
        out["accepted"] = false;
        out["reject_reason"] = "unknown_group";
        return out;
    }

    vm::CastRequest request;
    request.op = "cast";
    request.tick = static_cast<int>(tick_);
    request.rng.phantom_roll = 1.0;
    request.state.sanity = 100;
    request.state.backlash = false;
    request.wand.spirit = spirit_;
    request.wand.spirit_max = data_.wand.spirit_max;
    request.wand.regen_per_sec = data_.wand.regen_per_sec;
    request.wand.slots = static_cast<int>(group->segments.size());
    request.wand.sentences_per_cast = data_.wand.sentences_per_cast;
    request.wand.recharge_ticks = data_.wand.recharge_ticks;
    request.wand.ready_at_tick = ready_at_tick_;
    request.wand.ordered = true;
    request.wand.deck = group->segments;
    request.wand.cursor = 0;

    const vm::CastResult result = vm::cast(request, data_.catalog);

    if (result.accepted) {
        spirit_ = result.spirit_after;
        ready_at_tick_ = result.ready_at_tick_after;
    }

    out["accepted"] = result.accepted;
    out["reject_reason"] = String::utf8(result.reject_reason.c_str());
    Array actions;
    for (const vm::Value &action : result.actions) {
        actions.append(vm_value_to_variant(action));
    }
    out["actions"] = actions;
    Array consumed;
    for (const std::string &card_id : result.consumed) {
        consumed.append(String::utf8(card_id.c_str()));
    }
    out["consumed"] = consumed;
    out["spirit_after"] = result.spirit_after;
    out["spirit_max"] = data_.wand.spirit_max;
    out["sanity_after"] = result.sanity_after;
    out["backlash_after"] = result.backlash_after;
    out["cursor_after"] = result.cursor_after;
    out["round_ended"] = result.round_ended;
    out["ready_at_tick_after"] = result.ready_at_tick_after;
    out["action_count"] = result.action_count;
    out["spawn_count"] = result.spawn_count;
    out["max_depth"] = result.max_depth;
    Array events;
    for (const vm::Event &event : result.events) {
        events.append(String::utf8(event.code.c_str()));
    }
    out["events"] = events;
    return out;
}
