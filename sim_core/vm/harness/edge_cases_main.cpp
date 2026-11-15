// T3 边界测试（C++ 单测）——覆盖 T3 复审修复的 5 处实现与 spec 不符 / 新补写的口径。
//
// 独立于 30 条契约用例（tests/vm_cases/，那是 T1 冻结契约）；本文件只构造边界输入，
// 逐条断言 spec 语义。每条的标题都标注对应 spec 章节：
//   E1 §2.7 步骤 1→2：反噬分支必须先保留 phantom_slot_cleared 事件
//   E2 §2.4：触发子句执行次数只按 exec(spawn)=count×(1+Σpayload+Σtrigger) 计一次
//   E3 §2.4：count 被钳到 0 → 停止剩余展开（不再读/扣后续句）
//   E4 §2.4 + §7.4.1 ④：refund_spirit 计入「已用执行次数」预算
//   E5 §2.7 第 4 步补写 + §7.3 #6：15% 替换句带触发符头（Option B：游标停子句首）
//
// 运行：ctest -R vm_edge_cases   （或直接执行 build-vm/vm/vm_edge_cases）

#include <cmath>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "vm/talisman_vm.h"

namespace {

using vm::Value;

// ---------------------------------------------------------------------------
// 卡表（tests/vm_cases/cards.yaml 的字段子集；只放边界测试用到的卡）
// ---------------------------------------------------------------------------
vm::Card make_head(const std::string& id, double spirit_cost, Value effect) {
    vm::Card card;
    card.id = id;
    card.segment = vm::CardSegment::kHead;
    card.spirit_cost = spirit_cost;
    card.effect = std::move(effect);
    return card;
}

vm::Card make_body(const std::string& id, double spirit_cost, const std::string& element, double damage,
                   const std::string& damage_type, int pierce, Value payloads) {
    vm::Card card;
    card.id = id;
    card.segment = vm::CardSegment::kBody;
    card.spirit_cost = spirit_cost;
    card.element = element;
    card.damage = damage;
    card.damage_type = damage_type;
    card.pierce = pierce;
    card.payloads = std::move(payloads);
    return card;
}

vm::Card make_foot(const std::string& id, double spirit_cost, Value action, const std::string& timing = "") {
    vm::Card card;
    card.id = id;
    card.segment = vm::CardSegment::kFoot;
    card.spirit_cost = spirit_cost;
    card.action = std::move(action);
    card.timing = timing;
    return card;
}

vm::Card make_phantom(const std::string& id, Value effect) {
    vm::Card card;
    card.id = id;
    card.segment = vm::CardSegment::kPhantom;
    card.effect = std::move(effect);
    return card;
}

vm::CardCatalog build_catalog() {
    vm::CardCatalog catalog;
    catalog.cards.push_back(make_head(
        "head-chu-touch", 5, Value::make_object({{"trigger", Value::make_string("on_hit")}})));
    catalog.cards.push_back(make_head(
        "head-fenshen", 5, Value::make_object({{"projectile_mult", Value::make_number(2)}})));
    catalog.cards.push_back(make_body("body-flying-sword", 5, "金", 8, "金", 1, Value::make_array()));
    catalog.cards.push_back(make_body(
        "body-bifang-huo", 10, "火", 10, "火", 0,
        Value::make_array({Value::make_object({{"op", Value::make_string("ignite")},
                                               {"duration", Value::make_number(3)},
                                               {"spread", Value::make_bool(true)},
                                               {"damage_per_sec", Value::make_number(3)}})})));
    catalog.cards.push_back(make_foot(
        "foot-sha", 8, Value::make_object({{"op", Value::make_string("explode")},
                                           {"radius", Value::make_number(20)},
                                           {"damage", Value::make_number(15)},
                                           {"damage_type", Value::make_string("火")}})));
    catalog.cards.push_back(make_foot(
        "foot-zhen", 12, Value::make_object({{"op", Value::make_string("apply_status")},
                                             {"status", Value::make_string("stun")},
                                             {"duration", Value::make_number(1.5)}})));
    catalog.cards.push_back(make_foot(
        "foot-shi", 12, Value::make_object({{"op", Value::make_string("drain_life")},
                                            {"amount", Value::make_number(4)}})));
    catalog.cards.push_back(make_foot(
        "foot-hui", 0, Value::make_object({{"op", Value::make_string("refund_spirit")},
                                           {"amount", Value::make_number(8)}}),
        "sentence_end"));
    catalog.cards.push_back(make_phantom(
        "phantom-001", Value::make_object({{"op", Value::make_string("damage")},
                                           {"amount", Value::make_number(6)},
                                           {"damage_type", Value::make_string("阴")}})));
    return catalog;
}

// ---------------------------------------------------------------------------
// 断言工具
// ---------------------------------------------------------------------------
struct TestContext {
    int failures = 0;

    void expect(bool condition, const std::string& message) {
        if (condition) return;
        std::printf("    FAIL: %s\n", message.c_str());
        ++failures;
    }
    void expect_equal(long long actual, long long expected, const std::string& label) {
        if (actual == expected) return;
        std::printf("    FAIL: %s：期望 %lld，实际 %lld\n", label.c_str(), expected, actual);
        ++failures;
    }
    void expect_double(double actual, double expected, const std::string& label) {
        if (std::fabs(actual - expected) <= 1e-9) return;
        std::printf("    FAIL: %s：期望 %.15g，实际 %.15g\n", label.c_str(), expected, actual);
        ++failures;
    }
    void expect_string(const std::string& actual, const std::string& expected, const std::string& label) {
        if (actual == expected) return;
        std::printf("    FAIL: %s：期望 \"%s\"，实际 \"%s\"\n", label.c_str(), expected.c_str(),
                    actual.c_str());
        ++failures;
    }
    void expect_events(const vm::CastResult& result, const std::vector<std::string>& expected,
                       const std::string& label) {
        std::vector<std::string> actual;
        actual.reserve(result.events.size());
        for (const vm::Event& event : result.events) actual.push_back(event.code);
        if (actual == expected) return;
        std::printf("    FAIL: %s：期望事件序列 [", label.c_str());
        for (std::size_t index = 0; index < expected.size(); ++index) {
            std::printf("%s%s", index == 0 ? "" : ", ", expected[index].c_str());
        }
        std::printf("]，实际 [");
        for (std::size_t index = 0; index < actual.size(); ++index) {
            std::printf("%s%s", index == 0 ? "" : ", ", actual[index].c_str());
        }
        std::printf("]\n");
        ++failures;
    }
    void expect_string_array(const std::vector<std::string>& actual, const std::vector<std::string>& expected,
                             const std::string& label) {
        if (actual == expected) return;
        std::printf("    FAIL: %s\n", label.c_str());
        ++failures;
    }
    void expect_int_array(const std::vector<int>& actual, const std::vector<int>& expected,
                          const std::string& label) {
        if (actual == expected) return;
        std::printf("    FAIL: %s\n", label.c_str());
        ++failures;
    }
};

const Value* action_field(const Value& action, const char* key) { return action.find(key); }

std::string action_string(const Value& action, const char* key) {
    const Value* value = action_field(action, key);
    return (value != nullptr && value->is_string()) ? value->as_string() : std::string();
}

long long action_int(const Value& action, const char* key, long long fallback) {
    const Value* value = action_field(action, key);
    return (value != nullptr && value->is_number()) ? static_cast<long long>(value->as_number()) : fallback;
}

std::string event_slot_text(const vm::Event& event) {
    const Value* slot = event.data.find("slot");
    if (slot == nullptr || !slot->is_number()) return "?";
    return std::to_string(static_cast<int>(slot->as_number()));
}

// ---------------------------------------------------------------------------
// 公共请求构造
// ---------------------------------------------------------------------------
vm::CastRequest base_request() {
    vm::CastRequest request;
    request.op = "cast";
    request.tick = 0;
    request.state.sanity = 100;
    request.state.backlash = false;
    request.wand.spirit = 100;
    request.wand.spirit_max = 120;
    request.wand.regen_per_sec = 10;
    request.wand.sentences_per_cast = 1;
    request.wand.recharge_ticks = 30;
    request.wand.ready_at_tick = 0;
    request.wand.ordered = true;
    request.rng.phantom_roll = 1.0;
    return request;
}

void set_deck(vm::CastRequest* request, std::vector<std::string> deck) {
    request->wand.slots = static_cast<int>(deck.size());
    request->wand.deck = std::move(deck);
}

// ---------------------------------------------------------------------------
// E1 §2.7 步骤 1→2：反噬分支不得丢 phantom_slot_cleared
// ---------------------------------------------------------------------------
void run_e1(TestContext& context) {
    const vm::CardCatalog catalog = build_catalog();
    vm::CastRequest request = base_request();
    request.state.sanity = 40;        // ≥ 33 → 步骤 1 清幻影符
    request.state.backlash = true;    // 步骤 2 反噬
    request.state.phantom_slots = {1};
    request.wand.spirit = 50;
    request.wand.spirit_max = 80;
    set_deck(&request, {"body-flying-sword", ""});
    request.rng.has_phantom_card = true;
    request.rng.phantom_card = "phantom-001";

    const vm::CastResult result = vm::cast(request, catalog);
    context.expect(result.accepted, "accepted");
    context.expect_events(result, {"phantom_slot_cleared", "backlash_consumed", "round_end"},
                          "§2.7 步骤 1 的 phantom_slot_cleared 必须先于步骤 2 的 backlash_consumed");
    if (!result.events.empty() && result.events.front().code == "phantom_slot_cleared") {
        context.expect_string(event_slot_text(result.events.front()), "1", "phantom_slot_cleared 附加字段 slot");
    }
    context.expect_int_array(result.phantom_slots_after, {}, "幻影符清除后 phantom_slots_after = []");
    context.expect_double(result.spirit_after, 45.0, "反噬成本 = min(50, 5)");
    context.expect(result.sanity_after == 40, "反噬施法不扣神智");
    context.expect(!result.backlash_after, "I4：反噬消费后 backlash_after = false");
    context.expect_equal(static_cast<long long>(result.actions.size()), 1, "I1：反噬施法只有 1 个动作");
    if (!result.actions.empty()) {
        context.expect_string(action_string(result.actions[0], "op"), "phantom_cast", "反噬动作 op");
        context.expect_string(action_string(result.actions[0], "reason"), "backlash", "反噬动作 reason");
    }
    context.expect_equal(result.action_count, 1, "action_count");
    context.expect(result.round_ended, "读尽牌堆 → 回符");
    context.expect_equal(result.ready_at_tick_after, 30, "ready_at_tick_after = tick + recharge_ticks");
}

// ---------------------------------------------------------------------------
// E2 §2.4：触发子句执行次数只计一次（不得双向计入 used_actions）
// ---------------------------------------------------------------------------
void run_e2(TestContext& context) {
    const vm::CardCatalog catalog = build_catalog();
    vm::CastRequest request = base_request();
    request.wand.spirit = 100;
    request.wand.spirit_max = 120;
    // 主句：4×分身 + 敕·触 + 飞剑 → count = 16；触发子句：分身 + 飞剑 + 煞 + 镇
    // 子句 exec = 2 × (1 + 2) = 6；主句 per = 1 + 0 + 6 = 7
    // → count 应钳到 floor(64 / 7) = 9，action_count = 9 × 7 = 63（不是 8 / 56）。
    set_deck(&request, {"head-fenshen", "head-fenshen", "head-fenshen", "head-fenshen", "head-chu-touch",
                        "body-flying-sword", "head-fenshen", "body-flying-sword", "foot-sha", "foot-zhen"});

    const vm::CastResult result = vm::cast(request, catalog);
    context.expect(result.accepted, "accepted");
    context.expect_equal(static_cast<long long>(result.actions.size()), 1, "主句只生成 1 个 spawn");
    if (!result.actions.empty()) {
        context.expect_equal(action_int(result.actions[0], "count", -1), 9,
                             "§2.4：count = floor((64 − 已用 0) / per 7) = 9");
        context.expect_equal(vm::action_exec_count(result.actions[0]), 63,
                             "§2.4 exec(spawn)=count×(1+Σpayload+Σtrigger)=9×7=63");
    }
    context.expect_equal(result.action_count, 63, "action_count 只计一次子句执行次数");
    context.expect_equal(result.spawn_count, 11, "spawn_count = 9 + 2（§2.4 Σ spawn.count）");
    context.expect_equal(result.max_depth, 1, "max_depth");
    context.expect_double(result.spirit_after, 40.0, "spirit_after = 100 − 30 − 30");
    context.expect_events(result, {"budget_exhausted_action", "round_end"}, "预算事件 + 回符");
}

// ---------------------------------------------------------------------------
// E3 §2.4：count 被钳到 0 → 停止剩余展开（不读/不扣后续句）
// ---------------------------------------------------------------------------
void run_e3(TestContext& context) {
    const vm::CardCatalog catalog = build_catalog();
    vm::CastRequest request = base_request();
    request.wand.spirit = 100;
    request.wand.spirit_max = 120;
    request.wand.sentences_per_cast = 3;
    // 句 1：4×分身 + 飞剑 + 煞/镇/噬 → exec = 16 × (1+3) = 64（额度用尽）
    // 句 2：飞剑 → count 钳到 0，停止剩余展开；句 3 的牌不得再读/扣。
    set_deck(&request, {"head-fenshen", "head-fenshen", "head-fenshen", "head-fenshen", "body-flying-sword",
                        "foot-sha", "foot-zhen", "foot-shi", "body-flying-sword", "body-flying-sword"});

    const vm::CastResult result = vm::cast(request, catalog);
    context.expect(result.accepted, "accepted");
    context.expect_equal(static_cast<long long>(result.actions.size()), 1, "只有句 1 生成 spawn");
    if (!result.actions.empty()) {
        context.expect_equal(action_int(result.actions[0], "count", -1), 16, "句 1 count = 16（不截断）");
    }
    context.expect_equal(static_cast<long long>(result.consumed.size()), 9,
                         "句 3 的牌不得再读：consumed = 句 1(8) + 句 2(1) = 9");
    context.expect_equal(result.cursor_after, 9, "cursor_after = 起始游标 + 已 consumed 数");
    context.expect(!result.round_ended, "句 3 未读 → 未读尽 → 不回符");
    context.expect_double(result.spirit_after, 38.0, "spirit_after = 100 − 57 − 5（句 3 不扣）");
    context.expect_events(result, {"budget_exhausted_action"}, "只应有一条 budget_exhausted_action");
    context.expect_equal(result.action_count, 64, "action_count");
    context.expect_equal(result.spawn_count, 16, "spawn_count");
}

// ---------------------------------------------------------------------------
// E4 §2.4 + §7.4.1 ④：refund_spirit 计入「已用执行次数」预算
// ---------------------------------------------------------------------------
void run_e4(TestContext& context) {
    const vm::CardCatalog catalog = build_catalog();
    vm::CastRequest request = base_request();
    request.wand.spirit = 100;
    request.wand.spirit_max = 200;
    request.wand.sentences_per_cast = 2;
    // 句 1：飞剑 + 归 → spawn exec 1 + refund exec 1 = 已用 2（§7.4.1 ④）
    // 句 2：5×分身 + 飞剑 + 煞 + 镇 → per = 1 + 2 = 3；剩余额度 64 − 2 = 62
    // → count 应钳到 floor(62 / 3) = 20（若 refund 不计入预算则为 floor(63/3) = 21）。
    set_deck(&request, {"body-flying-sword", "foot-hui", "head-fenshen", "head-fenshen", "head-fenshen",
                        "head-fenshen", "head-fenshen", "body-flying-sword", "foot-sha", "foot-zhen"});

    const vm::CastResult result = vm::cast(request, catalog);
    context.expect(result.accepted, "accepted");
    context.expect_equal(static_cast<long long>(result.actions.size()), 3,
                         "动作 = [句1 spawn, 句1 refund, 句2 spawn]");
    if (result.actions.size() == 3) {
        context.expect_string(action_string(result.actions[1], "op"), "refund_spirit", "句 1 的归进动作列表");
        context.expect_equal(action_int(result.actions[2], "count", -1), 20,
                             "§7.4.1 ④：count = floor((64−2)/3) = 20");
    }
    context.expect_equal(result.action_count, 62, "action_count = 1 + 1(refund) + 20×3 = 62");
    context.expect_equal(result.spawn_count, 21, "spawn_count = 1 + 20");
    context.expect_double(result.spirit_after, 53.0, "spirit_after = 100 − 5 + 8 − 50");
    context.expect(result.round_ended, "读尽牌堆 → 回符");
    context.expect_events(result, {"budget_exhausted_action", "round_end"}, "预算事件 + 回符");
}

// ---------------------------------------------------------------------------
// E5 §2.7 第 4 步补写 + §7.3 #6：15% 替换句带触发符头（Option B）
// ---------------------------------------------------------------------------
void run_e5(TestContext& context) {
    const vm::CardCatalog catalog = build_catalog();
    vm::CastRequest request = base_request();
    request.state.sanity = 20;      // < 33：可触发 15% 替换
    request.state.phantom_slots = {3};
    request.wand.spirit = 100;
    request.wand.spirit_max = 120;
    set_deck(&request, {"head-chu-touch", "body-flying-sword", "foot-sha", "", "body-bifang-huo"});
    request.rng.phantom_roll = 0.10;
    request.rng.has_phantom_card = true;
    request.rng.phantom_card = "phantom-001";

    const vm::CastResult result = vm::cast(request, catalog);
    context.expect(result.accepted, "accepted");
    context.expect_events(result, {"phantom_substitute"},
                          "替换句的触发子句不展开：不得有 round_end（未读尽子句首卡）");
    context.expect_string_array(result.consumed, {"head-chu-touch", "body-flying-sword", "foot-sha"},
                                "consumed 只含主句直接符，不含触发子句的牌");
    context.expect_double(result.spirit_after, 82.0, "成本 = 主句直接符 5+5+8 = 18（子句 10 不扣）");
    context.expect_equal(result.cursor_after, 3, "游标停在子句首（own_end=3，不是 plan.end_cursor=4）");
    context.expect(!result.round_ended, "未读尽牌堆 → 不回符");
    context.expect_equal(static_cast<long long>(result.actions.size()), 1, "替换只产生 1 个 phantom_cast");
    if (!result.actions.empty()) {
        const Value& action = result.actions[0];
        context.expect_string(action_string(action, "op"), "phantom_cast", "动作 op");
        context.expect_string(action_string(action, "reason"), "substitute", "动作 reason");
        context.expect_string(action_string(action, "spell"), "phantom-001", "动作 spell");
        const Value* payloads = action_field(action, "payloads");
        context.expect(payloads != nullptr && payloads->is_array() && payloads->items().size() == 1,
                       "符脚保留为 payloads（explode）");
        const Value* effect = action_field(action, "effect");
        context.expect(effect != nullptr && effect->is_object() &&
                           action_string(*effect, "op") == "damage",
                       "幻符 effect 内联（§3.2 第 16 项）");
    }
    context.expect_equal(result.action_count, 1, "action_count = 1（§2.4 exec(其他 op)=1）");
    context.expect_equal(result.spawn_count, 0, "spawn_count = 0");
    context.expect(result.sanity_after == 20, "I5：替换不扣神智");
    context.expect_int_array(result.phantom_slots_after, {3}, "sanity < 33 且已有幻影符 → 不重复放置");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
struct EdgeTest {
    const char* name;
    const char* spec;
    void (*run)(TestContext&);
};

const EdgeTest kEdgeTests[] = {
    {"E1 反噬前先清幻影符：phantom_slot_cleared 不丢", "§2.7 步骤 1→2", run_e1},
    {"E2 触发子句执行次数只计一次（不重复计入预算）", "§2.4", run_e2},
    {"E3 count 被钳到 0 → 停止剩余展开（不读/不扣后续句）", "§2.4", run_e3},
    {"E4 refund_spirit 计入「已用执行次数」预算", "§2.4 + §7.4.1 ④", run_e4},
    {"E5 替换句带触发符头：不展开/不扣费/不计 consumed/游标停子句首", "§2.7 第 4 步补写 + §7.3 #6", run_e5},
};

}  // namespace

int main() {
    const int total = static_cast<int>(sizeof(kEdgeTests) / sizeof(kEdgeTests[0]));
    int failed = 0;
    std::printf("vm_edge_cases：T3 复审边界口径 C++ 单测（%d 条，对应 spec §2.4 / §2.7 / §7.4.1）\n\n", total);
    for (const EdgeTest& test : kEdgeTests) {
        std::printf("[%s] %s\n", test.spec, test.name);
        TestContext context;
        test.run(context);
        if (context.failures == 0) {
            std::printf("  PASS\n");
        } else {
            std::printf("  FAIL（%d 处不符）\n", context.failures);
            ++failed;
        }
    }
    std::printf("\nvm_edge_cases: %d/%d passed, %d failed\n", total - failed, total, failed);
    if (failed == 0) {
        std::printf("OK: 边界口径全部成立\n");
        return 0;
    }
    return 1;
}
