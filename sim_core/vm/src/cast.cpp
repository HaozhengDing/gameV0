#include "vm/talisman_vm.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace vm {
namespace {

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------
bool is_segment(const Card& card, CardSegment segment) { return card.segment == segment; }

std::string op_of(const Value& action) {
    const Value* op = action.find("op");
    return (op != nullptr && op->is_string()) ? op->as_string() : std::string();
}

double number_field(const Value& object, const std::string& key, double fallback) {
    const Value* value = object.find(key);
    return (value != nullptr && value->is_number()) ? value->as_number() : fallback;
}

// §2.4 计数定义：
//   exec(spawn) = spawn.count × (1 + Σ exec(p) for p in payloads + exec(trigger.actions))
//   exec(其他 op) = 1；exec(null) = 0
int exec_count_internal(const Value& action) {
    if (op_of(action) != "spawn_projectile") return 1;
    const double requested = number_field(action, "count", 1.0);
    int sub = 0;
    const Value* payloads = action.find("payloads");
    if (payloads != nullptr && payloads->is_array()) {
        for (const Value& payload : payloads->items()) sub += exec_count_internal(payload);
    }
    const Value* trigger = action.find("trigger");
    if (trigger != nullptr && trigger->is_object()) {
        const Value* actions = trigger->find("actions");
        if (actions != nullptr && actions->is_array()) {
            for (const Value& child : actions->items()) sub += exec_count_internal(child);
        }
    }
    return static_cast<int>(requested) * (1 + sub);
}

int spawn_count_internal(const Value& action) {
    if (op_of(action) != "spawn_projectile") return 0;
    int total = static_cast<int>(number_field(action, "count", 1.0));
    const Value* payloads = action.find("payloads");
    if (payloads != nullptr && payloads->is_array()) {
        for (const Value& payload : payloads->items()) total += spawn_count_internal(payload);
    }
    const Value* trigger = action.find("trigger");
    if (trigger != nullptr && trigger->is_object()) {
        const Value* actions = trigger->find("actions");
        if (actions != nullptr && actions->is_array()) {
            for (const Value& child : actions->items()) total += spawn_count_internal(child);
        }
    }
    return total;
}

int max_trigger_depth_internal(const Value& action) {
    int best = 0;
    const Value* trigger = action.find("trigger");
    if (op_of(action) == "spawn_projectile" && trigger != nullptr && trigger->is_object()) {
        best = static_cast<int>(number_field(*trigger, "depth", 0.0));
        const Value* actions = trigger->find("actions");
        if (actions != nullptr && actions->is_array()) {
            for (const Value& child : actions->items()) best = std::max(best, max_trigger_depth_internal(child));
        }
    }
    const Value* payloads = action.find("payloads");
    if (payloads != nullptr && payloads->is_array()) {
        for (const Value& payload : payloads->items()) best = std::max(best, max_trigger_depth_internal(payload));
    }
    return best;
}

// ---------------------------------------------------------------------------
// 阶段 A：解析（§2.1 / §2.3 / 附录 A）
// ---------------------------------------------------------------------------
struct ParsedSentence {
    bool invalid = false;
    std::vector<const Card*> heads;
    const Card* body = nullptr;
    std::vector<const Card*> feet;
    int start = 0;
    int own_end = 0;  // 本句自身卡片结束位置（不含触发子句的牌）
    double cost = 0.0;
    bool has_forbidden = false;
    std::vector<ParsedSentence> triggers;  // 每句最多 1 个（§2.3 第 6 条）
};

double sentence_total_cost(const ParsedSentence& sentence) {
    double total = sentence.cost;
    for (const ParsedSentence& trigger : sentence.triggers) total += sentence_total_cost(trigger);
    return total;
}

bool sentence_has_forbidden(const ParsedSentence& sentence) {
    if (sentence.has_forbidden) return true;
    for (const ParsedSentence& trigger : sentence.triggers) {
        if (sentence_has_forbidden(trigger)) return true;
    }
    return false;
}

void collect_own_ids(const ParsedSentence& sentence, std::vector<std::string>* ids) {
    for (const Card* head : sentence.heads) ids->push_back(head->id);
    if (sentence.body != nullptr) ids->push_back(sentence.body->id);
    for (const Card* foot : sentence.feet) ids->push_back(foot->id);
}

void collect_sentence_ids(const ParsedSentence& sentence, std::vector<std::string>* ids) {
    collect_own_ids(sentence, ids);
    for (const ParsedSentence& trigger : sentence.triggers) collect_sentence_ids(trigger, ids);
}

const Card* first_trigger_head(const ParsedSentence& sentence) {
    for (const Card* head : sentence.heads) {
        if (head->effect.is_null()) continue;
        const Value* trigger = head->effect.find("trigger");
        if (trigger != nullptr && trigger->is_string() && !trigger->as_string().empty()) return head;
    }
    return nullptr;
}

std::string trigger_kind_of(const Card& head) {
    if (head.effect.is_null()) return std::string();
    const Value* trigger = head.effect.find("trigger");
    return (trigger != nullptr && trigger->is_string()) ? trigger->as_string() : std::string();
}

class Parser {
public:
    struct RoundPlan {
        std::vector<ParsedSentence> sentences;
        int end_cursor = 0;
        double total_cost = 0.0;
        bool has_forbidden = false;
        std::vector<Event> events;
    };

    Parser(const std::vector<const Card*>& deck, int start_cursor, bool record_events)
        : deck_(deck), cursor_(start_cursor), record_events_(record_events) {}

    RoundPlan parse_round(int sentences_per_cast) {
        RoundPlan plan;
        for (int index = 0; index < sentences_per_cast; ++index) {
            if (cursor_ >= static_cast<int>(deck_.size())) break;
            plan.sentences.push_back(parse_sentence(0));
            plan.total_cost += sentence_total_cost(plan.sentences.back());
            if (sentence_has_forbidden(plan.sentences.back())) plan.has_forbidden = true;
        }
        plan.end_cursor = cursor_;
        plan.events = std::move(events_);
        return plan;
    }

private:
    ParsedSentence parse_sentence(int depth) {
        ParsedSentence sentence;
        sentence.start = cursor_;
        const int count = static_cast<int>(deck_.size());
        while (cursor_ < count && is_segment(*deck_[static_cast<std::size_t>(cursor_)], CardSegment::kHead)) {
            sentence.heads.push_back(deck_[static_cast<std::size_t>(cursor_)]);
            ++cursor_;
        }
        if (cursor_ < count && is_segment(*deck_[static_cast<std::size_t>(cursor_)], CardSegment::kBody)) {
            sentence.body = deck_[static_cast<std::size_t>(cursor_)];
            ++cursor_;
            while (cursor_ < count && is_segment(*deck_[static_cast<std::size_t>(cursor_)], CardSegment::kFoot)) {
                sentence.feet.push_back(deck_[static_cast<std::size_t>(cursor_)]);
                ++cursor_;
            }
        } else {
            // §2.6 无效句：吞掉「符头串 + 紧随的连续符脚串」（附录 A）。
            while (cursor_ < count && is_segment(*deck_[static_cast<std::size_t>(cursor_)], CardSegment::kFoot)) {
                sentence.feet.push_back(deck_[static_cast<std::size_t>(cursor_)]);
                ++cursor_;
            }
            sentence.invalid = true;
        }
        sentence.own_end = cursor_;
        for (const Card* head : sentence.heads) {
            sentence.cost += head->spirit_cost;
            sentence.has_forbidden = sentence.has_forbidden || head->forbidden;
        }
        if (sentence.body != nullptr) {
            sentence.cost += sentence.body->spirit_cost;
            sentence.has_forbidden = sentence.has_forbidden || sentence.body->forbidden;
        }
        for (const Card* foot : sentence.feet) {
            sentence.cost += foot->spirit_cost;
            sentence.has_forbidden = sentence.has_forbidden || foot->forbidden;
        }
        // §2.3：解析到带触发效果的符头时立即解析下一句；每句只认第一个触发符头。
        // 无效句不展开触发（§2.6「无效句里的符头：效果丢弃」；用例 VM-013 期望无 empty_trigger）。
        if (!sentence.invalid) {
            const Card* trigger_head = first_trigger_head(sentence);
            if (trigger_head != nullptr) {
                if (depth >= kMaxTriggerDepth) {
                    emit("depth_limit", Value::make_object({{"depth", Value::make_number(depth)}}));
                } else if (cursor_ >= count) {
                    emit("empty_trigger", Value::make_object({{"card", Value::make_string(trigger_head->id)}}));
                } else {
                    sentence.triggers.push_back(parse_sentence(depth + 1));
                }
            }
        }
        return sentence;
    }

    void emit(const std::string& code, Value data) {
        if (!record_events_) return;
        Event event;
        event.code = code;
        event.data = std::move(data);
        events_.push_back(std::move(event));
    }

    const std::vector<const Card*>& deck_;
    int cursor_ = 0;
    bool record_events_ = false;
    std::vector<Event> events_;
};

// ---------------------------------------------------------------------------
// 牌堆（§1.2 / 附录 A）：剔除 null 与幻影符位，按槽位升序
// ---------------------------------------------------------------------------
std::vector<const Card*> build_deck(const std::vector<std::string>& slots_cards,
                                    const std::vector<int>& phantom_slots,
                                    const CardCatalog& catalog) {
    std::vector<const Card*> deck;
    for (std::size_t index = 0; index < slots_cards.size(); ++index) {
        if (slots_cards[index].empty()) continue;
        bool occupied_by_phantom = false;
        for (int slot : phantom_slots) {
            if (slot >= 0 && static_cast<std::size_t>(slot) == index) {
                occupied_by_phantom = true;
                break;
            }
        }
        if (occupied_by_phantom) continue;
        const Card* card = catalog.find(slots_cards[index]);
        if (card == nullptr) continue;  // 防御：未定义卡按空位处理（用例不会出现）
        deck.push_back(card);
    }
    return deck;
}

// ---------------------------------------------------------------------------
// 阶段 B：执行（§2.2 / §2.4 / §2.5 / §2.7）
// ---------------------------------------------------------------------------
struct Execution {
    Execution(const CardCatalog& catalog_in, const CastRequest& request_in,
              const std::vector<const Card*>& deck_in)
        : catalog(catalog_in), request(request_in), deck(deck_in) {}

    const CardCatalog& catalog;
    const CastRequest& request;
    const std::vector<const Card*>& deck;
    double spirit = 0.0;
    int sanity = 0;
    bool backlash = false;
    std::vector<int> phantom_slots;
    int cursor = 0;
    std::vector<Event> events;
    std::vector<std::string> consumed;
    std::vector<Value> actions;
    long used_actions = 0;
    long used_projectiles = 0;
    bool budget_stopped = false;  // §2.4：count 被钳到 0 → 停止剩余展开
    bool round_ended = false;
    int ready_at_tick_after = 0;
};

void push_event(Execution& execution, const std::string& code, Value data = Value::make_object()) {
    Event event;
    event.code = code;
    event.data = std::move(data);
    execution.events.push_back(std::move(event));
}

void consume_own_cards(Execution& execution, const ParsedSentence& sentence) {
    collect_own_ids(sentence, &execution.consumed);
}

// §2.7 第 5/6 步：念出禁符 → 神智 −20、置「下一次施法反噬」，本次照常生效。
// 扣除时点与灵力同一原子时刻（§2.5「神智扣除（禁符）与灵力扣除同一时刻」）。
void apply_forbidden(Execution& execution, const ParsedSentence& sentence) {
    auto handle = [&execution](const Card& card) {
        if (!card.forbidden) return;
        execution.sanity = std::max(0, execution.sanity - kForbiddenSanityCost);
        push_event(execution, "forbidden_read", Value::make_object({{"card", Value::make_string(card.id)}}));
        execution.backlash = true;
        push_event(execution, "backlash_armed", Value::make_object());
    };
    for (const Card* head : sentence.heads) handle(*head);
    if (sentence.body != nullptr) handle(*sentence.body);
    for (const Card* foot : sentence.feet) handle(*foot);
}

// §3.2 伤害加成规则（天罡）：只乘 spawn.damage / explode.damage / damage.amount /
// drain_life.amount；不乘 ignite.damage_per_sec（S-0003）、不乘 extinguish_lantern.lanterns（S-0004）。
Value scale_damage(const Value& action, double damage_mult) {
    Value scaled = action;
    if (damage_mult == 1.0) return scaled;
    const std::string op = op_of(scaled);
    const char* field = nullptr;
    if (op == "spawn_projectile" || op == "explode") {
        field = "damage";
    } else if (op == "damage" || op == "drain_life") {
        field = "amount";
    }
    if (field == nullptr) return scaled;
    Value* value = scaled.find(field);
    if (value != nullptr && value->is_number()) {
        *value = Value::make_number(value->as_number() * damage_mult);
    }
    return scaled;
}

struct HeadEffects {
    double damage_mult = 1.0;
    long projectile_mult = 1;
};

HeadEffects fold_heads(const ParsedSentence& sentence) {
    HeadEffects effects;
    for (const Card* head : sentence.heads) {
        if (head->effect.is_null()) continue;
        const Value* damage_mult = head->effect.find("damage_mult");
        if (damage_mult != nullptr && damage_mult->is_number()) effects.damage_mult *= damage_mult->as_number();
        const Value* projectile_mult = head->effect.find("projectile_mult");
        if (projectile_mult != nullptr && projectile_mult->is_number()) {
            effects.projectile_mult *= static_cast<long>(projectile_mult->as_number());
        }
    }
    return effects;
}

// §3.2 payload 顺序：符胆自带 payloads（按卡表顺序）+ 附着的符脚动作（按牌堆顺序）。
// §1.3：timing: sentence_end 的符脚（归）挂顶层、句末立即执行，不作为命中载荷。
void collect_payloads(const ParsedSentence& sentence, double damage_mult, bool include_body_payloads,
                      std::vector<Value>* payloads, std::vector<Value>* sentence_end_actions) {
    if (include_body_payloads && sentence.body != nullptr && sentence.body->payloads.is_array()) {
        for (const Value& payload : sentence.body->payloads.items()) {
            payloads->push_back(scale_damage(payload, damage_mult));
        }
    }
    for (const Card* foot : sentence.feet) {
        if (foot->action.is_null()) continue;
        if (foot->timing == "sentence_end") {
            sentence_end_actions->push_back(scale_damage(foot->action, damage_mult));
        } else {
            payloads->push_back(scale_damage(foot->action, damage_mult));
        }
    }
}

// §2.5：归（timing: sentence_end）句末立即 refund_spirit，是唯一能从动作里改灵力的操作；
// clamp <= spirit_max（§4.4 第 2 条）。refund 动作本身仍进动作列表（§3.2 executor=VM）。
void apply_sentence_end_effects(Execution& execution, const ParsedSentence& sentence) {
    for (const Card* foot : sentence.feet) {
        if (foot->timing != "sentence_end" || foot->action.is_null()) continue;
        if (op_of(foot->action) != "refund_spirit") continue;
        const double amount = number_field(foot->action, "amount", 0.0);
        execution.spirit = std::min(execution.request.wand.spirit_max, execution.spirit + amount);
    }
}

Value make_spawn_action(const ParsedSentence& sentence, long count, double damage_mult,
                        std::vector<Value> payloads, Value trigger) {
    const Card& body = *sentence.body;
    std::vector<std::pair<std::string, Value>> members;
    members.emplace_back("op", Value::make_string("spawn_projectile"));
    members.emplace_back("spell", Value::make_string(body.id));
    members.emplace_back("count", Value::make_number(static_cast<double>(count)));
    members.emplace_back("damage", Value::make_number(body.damage * damage_mult));
    members.emplace_back("damage_type", Value::make_string(body.damage_type.empty() ? "none" : body.damage_type));
    members.emplace_back("element", Value::make_string(body.element.empty() ? "none" : body.element));
    members.emplace_back("pierce", Value::make_number(static_cast<double>(body.pierce)));
    // §3.2 默认值：speed=12、spread_deg=0、ttl_ticks=120。
    members.emplace_back("speed", Value::make_number(12.0));
    members.emplace_back("spread_deg", Value::make_number(0.0));
    members.emplace_back("ttl_ticks", Value::make_number(120.0));
    members.emplace_back("payloads", Value::make_array(std::move(payloads)));
    members.emplace_back("trigger", std::move(trigger));
    return Value::make_object(std::move(members));
}

Value make_phantom_action(const std::string& spell, const Value& effect, const std::string& reason,
                          std::vector<Value> payloads) {
    std::vector<std::pair<std::string, Value>> members;
    members.emplace_back("op", Value::make_string("phantom_cast"));
    members.emplace_back("spell", Value::make_string(spell));
    members.emplace_back("reason", Value::make_string(reason));
    members.emplace_back("effect", effect);
    members.emplace_back("payloads", Value::make_array(std::move(payloads)));
    return Value::make_object(std::move(members));
}

struct Expanded {
    std::vector<Value> actions;
    long exec_total = 0;  // 本句动作树的执行次数（§2.4 exec 定义；含句末顶层动作）
};

// 展开一个有效句（§2.1 阶段 B / §2.3 / §2.4）：
//   - 触发子句先扣费并展开（子句本身也可带触发，递归）；
//   - 再生成父 spawn，count = 本句符头 projectile_mult 之积；
//   - 预算（§2.4）只按「主句 spawn」结算：per = 1 + Σexec(payload) + exec(trigger.actions)，
//     已包含触发子句的执行次数（exec(spawn)=count×(1+Σpayload+Σtrigger)），
//     子句不再单独计入 used_actions/used_projectiles，避免重复计数；
//   - account_budget=false 用于触发子句：其执行次数作为父 spawn 的 per 的一部分只计一次。
Expanded expand_sentence(const ParsedSentence& sentence, int depth, int main_index, Execution& execution,
                         bool account_budget) {
    Expanded expanded;
    const HeadEffects heads = fold_heads(sentence);

    // ---- 触发子句（§2.3）：静态展开，共享游标，子句单独原子判费 ----
    Value trigger = Value::make_null();
    long trigger_exec = 0;
    if (!sentence.triggers.empty()) {
        const ParsedSentence& sub = sentence.triggers.front();
        const Card* trigger_head = first_trigger_head(sentence);
        const std::string kind = (trigger_head != nullptr) ? trigger_kind_of(*trigger_head) : std::string("on_hit");
        if (execution.spirit < sub.cost) {
            // §2.3 第 5 条 + §7.4.1 ①：子句灵力不足 → 不扣费、不展开（trigger = null），
            // 但子句的符按"解析已读出"处理：计入 consumed、游标按解析推进到子句末。
            collect_sentence_ids(sub, &execution.consumed);
            push_event(execution, "sub_fizzle_no_spirit");
        } else {
            execution.spirit -= sub.cost;
            consume_own_cards(execution, sub);
            if (sub.invalid) {
                push_event(execution, "invalid_sentence",
                           Value::make_object({{"sentence", Value::make_number(main_index)},
                                                {"depth", Value::make_number(depth + 1)}}));
            } else {
                apply_forbidden(execution, sub);
                Expanded sub_expanded = expand_sentence(sub, depth + 1, main_index, execution, /*account_budget=*/false);
                trigger_exec = sub_expanded.exec_total;
                std::vector<std::pair<std::string, Value>> trigger_members;
                trigger_members.emplace_back("kind", Value::make_string(kind));
                trigger_members.emplace_back("depth", Value::make_number(depth + 1));
                trigger_members.emplace_back("actions", Value::make_array(std::move(sub_expanded.actions)));
                trigger = Value::make_object(std::move(trigger_members));
            }
        }
    }

    // ---- payloads：符胆自带 + 连续符脚（§3.2）；归 走句末顶层 ----
    std::vector<Value> payloads;
    std::vector<Value> sentence_end_actions;
    collect_payloads(sentence, heads.damage_mult, true, &payloads, &sentence_end_actions);

    // ---- §2.4 预算钳制（“执行次数”不是“对象个数”）----
    long payload_exec = 0;
    for (const Value& payload : payloads) payload_exec += exec_count_internal(payload);
    const long per = 1 + payload_exec + trigger_exec;
    long count = heads.projectile_mult;
    if (account_budget) {
        const long remaining_actions = std::max(0L, static_cast<long>(kMaxActions) - execution.used_actions);
        const long affordable = (per > 0) ? (remaining_actions / per) : 0L;
        bool clamped_action = false;
        bool clamped_projectile = false;
        if (count > affordable) {
            count = affordable;
            clamped_action = true;
        }
        const long remaining_projectiles =
            std::max(0L, static_cast<long>(kMaxProjectiles) - execution.used_projectiles);
        if (count > remaining_projectiles) {
            count = remaining_projectiles;
            clamped_projectile = true;
        }
        if (clamped_action) {
            push_event(execution, "budget_exhausted_action",
                       Value::make_object({{"limit", Value::make_number(kMaxActions)}}));
        }
        if (clamped_projectile) {
            push_event(execution, "budget_exhausted_projectile",
                       Value::make_object({{"limit", Value::make_number(kMaxProjectiles)}}));
        }
        if (count <= 0) {
            // §2.4：count 被钳到 0 则不发，停止剩余展开（符已念出，灵力不退）。
            // 句末顶层动作（归）不是 spawn，仍照常生成并计入执行次数。
            execution.budget_stopped = true;
            for (Value& action : sentence_end_actions) expanded.actions.push_back(std::move(action));
            expanded.exec_total = static_cast<long>(sentence_end_actions.size());
            execution.used_actions += expanded.exec_total;
            return expanded;
        }
        execution.used_actions += count * per;
        execution.used_projectiles += count;
    }
    if (count <= 0) return expanded;  // 防御：非主句 spawn 的 count 恒 ≥ 1

    expanded.actions.push_back (make_spawn_action(sentence, count, heads.damage_mult, std::move(payloads), std::move(trigger)));
    for (Value& action : sentence_end_actions) expanded.actions.push_back(std::move(action));
    expanded.exec_total = count * per + static_cast<long>(sentence_end_actions.size());
    if (account_budget) {
        // §2.4 exec(其他 op)=1：句末顶层动作（归）也占“已用执行次数”。
        execution.used_actions += static_cast<long>(sentence_end_actions.size());
    }
    return expanded;
}

// §2.2 finish：牌堆读尽 → 回符（§2.7 第 7 步）。
void apply_round_end(Execution& execution) {
    if (execution.cursor != static_cast<int>(execution.deck.size())) return;
    execution.cursor = 0;
    execution.round_ended = true;
    execution.ready_at_tick_after = execution.request.tick + execution.request.wand.recharge_ticks;
    push_event(execution, "round_end",
               Value::make_object({{"ready_at_tick", Value::make_number(execution.ready_at_tick_after)}}));
}

// §2.7 第 8 步：sanity < 33 且没有幻影符 → 按注入的 rng.phantom_slot 占 1 格。
// 只占「不含禁符的符位」（§5.2 / S-0004；空槽位不含禁符，VM-022 注入空槽位 2）。
void apply_phantom_placement(Execution& execution) {
    if (execution.sanity >= kRechargingSanity) return;
    if (!execution.phantom_slots.empty()) return;
    if (!execution.request.rng.has_phantom_slot) return;
    const int slot = execution.request.rng.phantom_slot;
    if (slot < 0 || slot >= execution.request.wand.slots) return;
    if (slot < static_cast<int>(execution.request.wand.deck.size())) {
        const Card* card = execution.catalog.find(execution.request.wand.deck[static_cast<std::size_t>(slot)]);
        if (card != nullptr && card->forbidden) return;
    }
    execution.phantom_slots.push_back(slot);
    push_event(execution, "phantom_slot_added", Value::make_object({{"slot", Value::make_number(slot)}}));
}

CastResult make_result(Execution& execution) {
    CastResult result;
    result.accepted = true;
    result.actions = std::move(execution.actions);
    result.consumed = std::move(execution.consumed);
    result.spirit_after = execution.spirit;
    result.sanity_after = execution.sanity;
    result.backlash_after = execution.backlash;
    result.phantom_slots_after = std::move(execution.phantom_slots);
    result.cursor_after = execution.cursor;
    result.round_ended = execution.round_ended;
    result.ready_at_tick_after = execution.ready_at_tick_after;
    result.events = std::move(execution.events);
    for (const Value& action : result.actions) {
        result.action_count += action_exec_count(action);
        result.spawn_count += spawn_count_of(action);
        result.max_depth = std::max(result.max_depth, max_trigger_depth_of(action));
    }
    return result;
}

}  // namespace

// ---------------------------------------------------------------------------
// §2.4 派生计数（公开给测试 / 调试）
// ---------------------------------------------------------------------------
int action_exec_count(const Value& action) { return exec_count_internal(action); }
int spawn_count_of(const Value& action) { return spawn_count_internal(action); }
int max_trigger_depth_of(const Value& action) { return max_trigger_depth_internal(action); }

// ---------------------------------------------------------------------------
// cast 主流程（§2.2 伪代码 + §2.7 八步状态机）
// ---------------------------------------------------------------------------
CastResult cast(const CastRequest& request, const CardCatalog& catalog) {
    CastResult result;
    result.spirit_after = request.wand.spirit;
    result.sanity_after = request.state.sanity;
    result.backlash_after = request.state.backlash;
    result.phantom_slots_after = request.state.phantom_slots;
    result.cursor_after = request.wand.cursor;
    result.ready_at_tick_after = request.wand.ready_at_tick;

    // 步骤 0（§2.7）：回符中拒绝施法；不消费反噬（I3）。
    if (request.tick < request.wand.ready_at_tick) {
        result.accepted = false;
        result.reject_reason = "recharging";
        Event event;
        event.code = "rejected_recharging";
        result.events.push_back(std::move(event));
        return result;
    }

    // 步骤 1（§2.7）：sanity >= 33 且幻影符非空 → 清除（必须在牌堆构建与空牌判定之前）。
    std::vector<int> phantom_slots = request.state.phantom_slots;
    std::vector<Event> events;
    if (request.state.sanity >= kRechargingSanity && !phantom_slots.empty()) {
        for (int slot : phantom_slots) {
            Event event;
            event.code = "phantom_slot_cleared";
            event.data = Value::make_object({{"slot", Value::make_number(slot)}});
            events.push_back(std::move(event));
        }
        phantom_slots.clear();
    }

    const std::vector<const Card*> deck = build_deck(request.wand.deck, phantom_slots, catalog);

    // 步骤 1.5（§2.2）：空牌判定（清理后再判）。
    if (deck.empty()) {
        result.accepted = false;
        result.reject_reason = "empty_deck";
        result.phantom_slots_after = phantom_slots;
        Event event;
        event.code = "rejected_empty_deck";
        events.push_back(std::move(event));
        result.events = std::move(events);
        return result;
    }

    Execution execution(catalog, request, deck);
    execution.spirit = request.wand.spirit;
    execution.sanity = request.state.sanity;
    execution.backlash = request.state.backlash;
    execution.phantom_slots = std::move(phantom_slots);
    execution.cursor = request.wand.cursor;
    execution.ready_at_tick_after = request.wand.ready_at_tick;

    // 步骤 2（§2.7）：反噬 → 整次替换为 1 个幻符；只解析不执行；不记 depth_limit/empty_trigger。
    if (execution.backlash) {
        // §2.7 步骤 1 先于步骤 2：sanity >= 33 时清幻影符的 phantom_slot_cleared 事件
        // 必须先并入事件流，再走反噬替换（否则该事件丢失）。
        execution.events = std::move(events);
        Parser parser(deck, execution.cursor, /*record_events=*/false);
        Parser::RoundPlan plan = parser.parse_round(request.wand.sentences_per_cast);
        const double cost = std::min(execution.spirit, plan.total_cost);
        execution.spirit -= cost;
        execution.backlash = false;
        push_event(execution, "backlash_consumed");
        for (const ParsedSentence& sentence : plan.sentences) collect_sentence_ids(sentence, &execution.consumed);
        execution.cursor = plan.end_cursor;
        const Card* phantom = request.rng.has_phantom_card ? catalog.find(request.rng.phantom_card) : nullptr;
        const Value effect = (phantom != nullptr) ? phantom->effect : Value::make_null();
        const std::string spell = (phantom != nullptr) ? phantom->id : request.rng.phantom_card;
        execution.actions.push_back(make_phantom_action(spell, effect, "backlash", {}));
        apply_round_end(execution);          // 仍判回符
        apply_phantom_placement(execution);  // 仍判幻影符放置
        return make_result(execution);
    }

    // 步骤 3（§2.2）：解析主句 + 深度内触发子句（只读句法树）。
    Parser parser(deck, execution.cursor, /*record_events=*/true);
    Parser::RoundPlan plan = parser.parse_round(request.wand.sentences_per_cast);
    for (Event& event : plan.events) events.push_back(std::move(event));
    execution.events = std::move(events);

    // 步骤 4（§2.7）：sanity < 33 且本次不含禁符 → 15% 把主句第一个符胆替换为幻符。
    int substitute_index = -1;
    const Card* substitute_phantom = nullptr;
    if (request.state.sanity < kRechargingSanity && !plan.has_forbidden &&
        request.rng.phantom_roll < kPhantomCastChance && request.rng.has_phantom_card) {
        const Card* phantom = catalog.find(request.rng.phantom_card);
        if (phantom != nullptr) {
            for (std::size_t index = 0; index < plan.sentences.size(); ++index) {
                if (!plan.sentences[index].invalid && plan.sentences[index].body != nullptr) {
                    substitute_index = static_cast<int>(index);
                    break;
                }
            }
            if (substitute_index >= 0) {
                substitute_phantom = phantom;
                push_event(execution, "phantom_substitute",
                           Value::make_object({{"card", Value::make_string(plan.sentences[static_cast<std::size_t>(substitute_index)].body->id)}}));
            }
        }
    }

    // 步骤 5/6（§2.7）：逐句判费扣费、生成动作树；禁符本次照常生效并置反噬。
    for (std::size_t index = 0; index < plan.sentences.size(); ++index) {
        const ParsedSentence& sentence = plan.sentences[index];
        if (execution.spirit < sentence.cost) {
            // §2.5 + §7.4.1 ②：整句不念、不扣、无动作、游标停在句首、不触发回符、
            // 不做幻影符放置；cursor_after = 起始游标 + 已 consumed 数。
            push_event(execution, "fizzle_no_spirit",
                       Value::make_object({{"sentence", Value::make_number(static_cast<double>(index))}}));
            execution.cursor = request.wand.cursor + static_cast<int>(execution.consumed.size());
            return make_result(execution);
        }
        execution.spirit -= sentence.cost;
        consume_own_cards(execution, sentence);
        if (sentence.invalid) {
            // §2.6：无效句已扣费、无动作、游标推进，继续读下一句。
            push_event(execution, "invalid_sentence",
                       Value::make_object({{"sentence", Value::make_number(static_cast<double>(index))}}));
            continue;
        }
        apply_forbidden(execution, sentence);

        if (static_cast<int>(index) == substitute_index) {
            // §2.7 第 4 步 + 补写（Option B）：只换符胆；符脚保留为 payloads；成本不变。
            // 若该句带触发符头：子句不展开、不扣灵力、不计 consumed，游标停在子句首
            // （用被替换句的 own_end，不是 plan.end_cursor）；未读尽则不回符。
            const HeadEffects heads = fold_heads(sentence);
            std::vector<Value> payloads;
            std::vector<Value> sentence_end_actions;
            collect_payloads(sentence, heads.damage_mult, /*include_body_payloads=*/false,
                             &payloads, &sentence_end_actions);
            execution.actions.push_back(make_phantom_action(substitute_phantom->id, substitute_phantom->effect,
                                                            "substitute", std::move(payloads)));
            for (Value& action : sentence_end_actions) execution.actions.push_back(std::move(action));
            // §7.4.1 ④：refund_spirit 计入「已用执行次数」；幻符本身 exec = 1（§2.4）。
            execution.used_actions += 1 + static_cast<long>(sentence_end_actions.size());
            apply_sentence_end_effects(execution, sentence);
            if (!sentence.triggers.empty()) {
                // 多句施法 + 替换 + 触发符头读法未定义（spec §7.4 待定）；本实现对
                // sentences_per_cast=1 按补写语义收尾（游标停子句首、不回符），
                // 多句时不再继续读后续主句（与"游标停在子句首"一致）。
                execution.cursor = sentence.own_end;
                apply_round_end(execution);
                apply_phantom_placement(execution);
                return make_result(execution);
            }
            continue;
        }

        Expanded expanded = expand_sentence(sentence, 0, static_cast<int>(index), execution, /*account_budget=*/true);
        for (Value& action : expanded.actions) execution.actions.push_back(std::move(action));
        apply_sentence_end_effects(execution, sentence);
        if (execution.budget_stopped) {
            // §2.4：count 被钳到 0 则不发，停止剩余展开（不再读/扣后续句）；
            // 游标停在已 consumed 处；收尾仍按 §2.7 步骤 7/8 判回符/幻影符放置。
            execution.cursor = request.wand.cursor + static_cast<int>(execution.consumed.size());
            apply_round_end(execution);
            apply_phantom_placement(execution);
            return make_result(execution);
        }
    }

    // 步骤 7/8（§2.7）：回符判定 → 幻影符放置。
    execution.cursor = plan.end_cursor;
    apply_round_end(execution);
    apply_phantom_placement(execution);

    return make_result(execution);
}

}  // namespace vm