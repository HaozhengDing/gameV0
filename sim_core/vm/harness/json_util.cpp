#include "json_util.h"

#include <cstddef>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace vmtest {
namespace {

vm::Card make_card(const simcore::json::Value& raw, vm::CardSegment segment) {
    vm::Card card;
    card.segment = segment;
    card.id = raw.string_or("id", "");
    card.spirit_cost = raw.number_or("spirit_cost", 0.0);
    card.forbidden = raw.bool_or("forbidden", false);
    card.timing = raw.string_or("timing", "");
    card.element = raw.string_or("element", "");
    card.damage_type = raw.string_or("damage_type", "");
    card.damage = raw.number_or("damage", 0.0);
    card.pierce = static_cast<int>(raw.number_or("pierce", 0.0));
    const simcore::json::Value* payloads = raw.find("payloads");
    if (payloads != nullptr && payloads->is_array()) card.payloads = from_json(*payloads);
    const simcore::json::Value* action = raw.find("action");
    if (action != nullptr && action->is_object()) card.action = from_json(*action);
    const simcore::json::Value* effect = raw.find("effect");
    if (effect != nullptr && effect->is_object()) card.effect = from_json(*effect);
    return card;
}

void append_segment(const simcore::json::Value& segments, const char* key, vm::CardSegment segment,
                    vm::CardCatalog* catalog) {
    const simcore::json::Value* list = segments.find(key);
    if (list == nullptr || !list->is_array()) return;
    for (const simcore::json::Value& raw : list->arr) {
        catalog->cards.push_back(make_card(raw, segment));
    }
}

void append_int_array(const simcore::json::Value& value, std::vector<int>* out) {
    if (!value.is_array()) return;
    for (const simcore::json::Value& item : value.arr) {
        if (item.is_number()) out->push_back(static_cast<int>(item.number));
    }
}

}  // namespace

vm::Value from_json(const simcore::json::Value& value) {
    switch (value.type) {
        case simcore::json::Value::NUL:
            return vm::Value::make_null();
        case simcore::json::Value::BOOL:
            return vm::Value::make_bool(value.boolean);
        case simcore::json::Value::NUMBER:
            return vm::Value::make_number(value.number);
        case simcore::json::Value::STRING:
            return vm::Value::make_string(value.str);
        case simcore::json::Value::ARRAY: {
            std::vector<vm::Value> items;
            items.reserve(value.arr.size());
            for (const simcore::json::Value& item : value.arr) items.push_back(from_json(item));
            return vm::Value::make_array(std::move(items));
        }
        case simcore::json::Value::OBJECT: {
            std::vector<std::pair<std::string, vm::Value>> members;
            members.reserve(value.obj.size());
            for (const auto& member : value.obj) members.emplace_back(member.first, from_json(member.second));
            return vm::Value::make_object(std::move(members));
        }
    }
    return vm::Value::make_null();
}

const simcore::json::Value& require_member(const simcore::json::Value& object, const char* key) {
    const simcore::json::Value* value = object.find(key);
    if (value == nullptr) throw std::runtime_error(std::string("cases JSON 缺字段: ") + key);
    return *value;
}

int int_field(const simcore::json::Value& object, const char* key) {
    return static_cast<int>(require_member(object, key).number);
}

double number_field(const simcore::json::Value& object, const char* key) {
    return require_member(object, key).number;
}

bool bool_field(const simcore::json::Value& object, const char* key) {
    return require_member(object, key).boolean;
}

std::string string_field(const simcore::json::Value& object, const char* key) {
    return require_member(object, key).str;
}

vm::CardCatalog build_card_catalog(const simcore::json::Value& cards_document) {
    vm::CardCatalog catalog;
    const simcore::json::Value* segments = cards_document.find("segments");
    if (segments != nullptr && segments->is_object()) {
        append_segment(*segments, "head", vm::CardSegment::kHead, &catalog);
        append_segment(*segments, "body", vm::CardSegment::kBody, &catalog);
        append_segment(*segments, "foot", vm::CardSegment::kFoot, &catalog);
    }
    const simcore::json::Value* phantoms = cards_document.find("phantom_pool");
    if (phantoms != nullptr && phantoms->is_array()) {
        for (const simcore::json::Value& raw : phantoms->arr) {
            catalog.cards.push_back(make_card(raw, vm::CardSegment::kPhantom));
        }
    }
    return catalog;
}

vm::CastRequest build_cast_request(const simcore::json::Value& case_document) {
    const simcore::json::Value& initial = require_member(case_document, "initial");
    const simcore::json::Value& input = require_member(case_document, "input");
    const simcore::json::Value& rng = require_member(input, "rng");
    const simcore::json::Value& wand = require_member(initial, "wand");

    vm::CastRequest request;
    request.op = input.string_or("op", "cast");
    request.tick = int_field(initial, "tick");
    request.state.sanity = int_field(initial, "sanity");
    request.state.backlash = bool_field(initial, "backlash");
    append_int_array(require_member(initial, "phantom_slots"), &request.state.phantom_slots);

    request.wand.spirit = number_field(wand, "spirit");
    request.wand.spirit_max = number_field(wand, "spirit_max");
    request.wand.regen_per_sec = number_field(wand, "regen_per_sec");
    request.wand.slots = int_field(wand, "slots");
    request.wand.sentences_per_cast = int_field(wand, "sentences_per_cast");
    request.wand.recharge_ticks = int_field(wand, "recharge_ticks");
    request.wand.ready_at_tick = int_field(wand, "ready_at_tick");
    request.wand.ordered = bool_field(wand, "ordered");
    request.wand.cursor = int_field(wand, "cursor");
    const simcore::json::Value& deck = require_member(wand, "deck");
    for (const simcore::json::Value& slot : deck.arr) {
        request.wand.deck.push_back(slot.is_string() ? slot.str : std::string());
    }

    request.rng.phantom_roll = number_field(rng, "phantom_roll");
    const simcore::json::Value* phantom_slot = rng.find("phantom_slot");
    if (phantom_slot != nullptr && phantom_slot->is_number()) {
        request.rng.has_phantom_slot = true;
        request.rng.phantom_slot = static_cast<int>(phantom_slot->number);
    }
    const simcore::json::Value* phantom_card = rng.find("phantom_card");
    if (phantom_card != nullptr && phantom_card->is_string()) {
        request.rng.has_phantom_card = true;
        request.rng.phantom_card = phantom_card->str;
    }
    return request;
}

}  // namespace vmtest
