#ifndef VM_TALISMAN_VM_H
#define VM_TALISMAN_VM_H

// T3 参考符箓 VM —— 契约 C-VM / C-ACT 的 C++17 实现（纯函数，无全局状态）。
//
// 规格：docs/tech/talisman-vm-spec.md
//   §2   执行模型（解析/执行两阶段、预算、灵力、无效句、禁符/幻符/幻影符时序）
//   §3   C-ACT：16 种动作、字段默认值、payload 顺序、伤害加成规则
//   §4   C-VM：CastRequest / CastResult / 事件码
//   §7.5 T3 实现清单：cast() 不碰世界、不碰引擎、无全局状态
//
// 模块边界：本库只依赖标准库。卡表 CardCatalog 是**只读外部输入**
// （§7.5「输入：卡表从 tests/vm_cases/cards.yaml 读」），不是全局状态。

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace vm {

// ---------------------------------------------------------------------------
// 数值常量（出处：spec §2.4 / §2.7、data/magic_numbers.json sanity 段、S-0004）
// ---------------------------------------------------------------------------
// §2.4 表「max_trigger_depth = 3（建议值）」。
inline constexpr int kMaxTriggerDepth = 3;
// §2.4 表「max_actions = 64（建议值）」。
inline constexpr int kMaxActions = 64;
// §2.4 表「max_projectiles = 32（建议值）」。
inline constexpr int kMaxProjectiles = 32;
// §2.7 第 1/2/4/8 步的「sanity >= 33 / < 33」分界（S-0004 幻影符恢复阈值）。
inline constexpr int kRechargingSanity = 33;
// §2.7 第 4 步：phantom_cast_chance = 0.15（data/magic_numbers.json）。
inline constexpr double kPhantomCastChance = 0.15;
// §2.7 第 5 步：forbidden_cast_cost = 20（data/magic_numbers.json）。
inline constexpr int kForbiddenSanityCost = 20;
// §2.7 第 8 步：phantom_slots = 1（data/magic_numbers.json）。
inline constexpr int kPhantomSlotCount = 1;

// ---------------------------------------------------------------------------
// 通用 JSON 形状的值（C-ACT 动作 / trigger / effect 都是对象；见 §3.2）
// 用同一套值类型承载卡表载荷与输出动作，避免为 16 种 op 各写一套 struct。
// ---------------------------------------------------------------------------
class Value {
public:
    enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };

    Value() = default;

    static Value make_null() { return Value(); }
    static Value make_bool(bool value) {
        Value v;
        v.type_ = Type::kBool;
        v.bool_ = value;
        return v;
    }
    static Value make_number(double value) {
        Value v;
        v.type_ = Type::kNumber;
        v.number_ = value;
        return v;
    }
    static Value make_string(std::string value) {
        Value v;
        v.type_ = Type::kString;
        v.string_ = std::move(value);
        return v;
    }
    static Value make_array(std::vector<Value> items = {}) {
        Value v;
        v.type_ = Type::kArray;
        v.array_ = std::move(items);
        return v;
    }
    static Value make_object(std::vector<std::pair<std::string, Value>> members = {}) {
        Value v;
        v.type_ = Type::kObject;
        v.object_ = std::move(members);
        return v;
    }

    Type type() const { return type_; }
    bool is_null() const { return type_ == Type::kNull; }
    bool is_bool() const { return type_ == Type::kBool; }
    bool is_number() const { return type_ == Type::kNumber; }
    bool is_string() const { return type_ == Type::kString; }
    bool is_array() const { return type_ == Type::kArray; }
    bool is_object() const { return type_ == Type::kObject; }

    bool as_bool() const { return bool_; }
    double as_number() const { return number_; }
    const std::string& as_string() const { return string_; }
    const std::vector<Value>& items() const { return array_; }
    std::vector<Value>& items() { return array_; }
    const std::vector<std::pair<std::string, Value>>& members() const { return object_; }
    std::vector<std::pair<std::string, Value>>& members() { return object_; }

    // 对象成员访问；非对象或不存在返回 nullptr。
    const Value* find(const std::string& key) const {
        if (type_ != Type::kObject) return nullptr;
        for (const auto& member : object_) {
            if (member.first == key) return &member.second;
        }
        return nullptr;
    }
    Value* find(const std::string& key) {
        if (type_ != Type::kObject) return nullptr;
        for (auto& member : object_) {
            if (member.first == key) return &member.second;
        }
        return nullptr;
    }
    bool has(const std::string& key) const { return find(key) != nullptr; }
    // 替换已存在成员；不存在则追加（保持插入顺序）。
    void set(const std::string& key, Value value) {
        if (type_ != Type::kObject) {
            type_ = Type::kObject;
            object_.clear();
        }
        for (auto& member : object_) {
            if (member.first == key) {
                member.second = std::move(value);
                return;
            }
        }
        object_.emplace_back(key, std::move(value));
    }

private:
    Type type_ = Type::kNull;
    bool bool_ = false;
    double number_ = 0.0;
    std::string string_;
    std::vector<Value> array_;
    std::vector<std::pair<std::string, Value>> object_;
};

// ---------------------------------------------------------------------------
// 卡表（只读输入；§5.1 测试替身卡表的字段子集）
// ---------------------------------------------------------------------------
enum class CardSegment { kHead, kBody, kFoot, kPhantom };

struct Card {
    std::string id;
    CardSegment segment = CardSegment::kBody;
    double spirit_cost = 0.0;  // 句成本 = Σ 本句直接符的 spirit_cost（§2.5）
    bool forbidden = false;    // 禁符（§2.7 第 5 步）
    std::string timing;        // 符脚 timing；"sentence_end" 表示句末顶层执行（§1.3）
    std::string element;       // 空串 = C-ACT 默认 "none"（§3.2）
    std::string damage_type;   // 空串 = C-ACT 默认 "none"（§3.2）
    double damage = 0.0;
    int pierce = 0;
    Value payloads = Value::make_array();  // 符胆自带载荷（§3.2 payload 顺序）
    Value action = Value::make_null();     // 符脚动作（§3.2）
    Value effect = Value::make_null();     // 符头 effect / 幻符 effect
};

struct CardCatalog {
    std::vector<Card> cards;

    const Card* find(const std::string& id) const {
        for (const Card& card : cards) {
            if (card.id == id) return &card;
        }
        return nullptr;
    }
};

// ---------------------------------------------------------------------------
// C-VM 输入（§4.1 CastRequest）
// ---------------------------------------------------------------------------
struct RngInput {
    double phantom_roll = 1.0;      // <33 的 15% 骰；不掷骰给 1.0（§4.1）
    bool has_phantom_slot = false;  // rng.phantom_slot: int | null
    int phantom_slot = 0;
    bool has_phantom_card = false;  // rng.phantom_card: string | null
    std::string phantom_card;
};

struct WitchState {
    int sanity = 100;  // 0–100（§4.1）
    bool backlash = false;
    std::vector<int> phantom_slots;
};

struct Wand {
    double spirit = 0.0;
    double spirit_max = 0.0;
    double regen_per_sec = 0.0;  // 仅记录，VM 不使用（§4.1）
    int slots = 0;
    int sentences_per_cast = 1;
    int recharge_ticks = 0;
    int ready_at_tick = 0;
    bool ordered = true;                // VM 只记录，洗牌在调度层（§1.2 第 6 条）
    std::vector<std::string> deck;      // 长度 = slots；空串表示 null 槽位
    int cursor = 0;                     // 牌堆下标（不含空位/幻影位，§4.1）
};

struct CastRequest {
    std::string op = "cast";  // §4.1 只定义 cast
    int tick = 0;
    RngInput rng;
    WitchState state;
    Wand wand;
};

// ---------------------------------------------------------------------------
// C-VM 输出（§4.2 CastResult / §4.3 事件）
// ---------------------------------------------------------------------------
struct Event {
    std::string code;  // §4.3 事件码
    Value data = Value::make_object();  // 附加字段（§4.3 表）
};

struct CastResult {
    bool accepted = false;
    std::string reject_reason;  // "" 等价于 null；"recharging" / "empty_deck"（§4.2）
    std::vector<Value> actions;             // C-ACT 动作列表（§3）
    std::vector<std::string> consumed;      // 读出的符（按读出顺序，含触发子句，§4.2）
    double spirit_after = 0.0;
    int sanity_after = 0;
    bool backlash_after = false;
    std::vector<int> phantom_slots_after;
    int cursor_after = 0;
    bool round_ended = false;
    int ready_at_tick_after = 0;
    std::vector<Event> events;
    int action_count = 0;  // §2.4 计数定义
    int spawn_count = 0;   // Σ spawn_projectile.count（§2.4）
    int max_depth = 0;     // 动作树 trigger.depth 最大值（§2.4）
};

// ---------------------------------------------------------------------------
// 纯函数入口（§7.5）
// ---------------------------------------------------------------------------
// 不碰世界 / 引擎 / 全局状态；唯一外部数据是只读卡表（§7.5）。
CastResult cast(const CastRequest& request, const CardCatalog& catalog);

// §2.4 计数定义，供调用方 / 测试 harness 复算（实现见 cast.cpp）。
int action_exec_count(const Value& action);
int spawn_count_of(const Value& action);
int max_trigger_depth_of(const Value& action);

}  // namespace vm

#endif  // VM_TALISMAN_VM_H
