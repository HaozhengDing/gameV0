#ifndef GDSIM_VM_NODE_H
#define GDSIM_VM_NODE_H

// TalismanVMNode：把 T3 参考符箓 VM（sim_core/vm，契约 C-VM/C-ACT）暴露给 Godot。
// 纯逻辑节点：不碰世界；cast_group() 返回 C-ACT 动作列表（Array[Dictionary]），
// 由 GDScript 世界层执行（T4b 的 executor）。卡表来自 data/talismans.json。

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include "card_data.h"

namespace godot {

class TalismanVMNode : public Node {
    GDCLASS(TalismanVMNode, Node)

    gdsim::CardData data_;
    double spirit_ = 80.0;
    int64_t tick_ = 0;
    int ready_at_tick_ = 0;

public:
    bool load_cards(const String &p_path);
    bool is_loaded() const;

    // 调度层（T4b 简化）：每 sim tick 调一次 → 内部 tick+1 并回灵
    void tick_advance();
    void reset();

    // 查询
    Array get_group_ids() const;
    Array get_groups() const;
    double get_spirit() const;
    double get_spirit_max() const;
    int64_t get_tick() const;
    int64_t get_ready_at_tick() const;
    bool get_is_recharging() const;

    // 按符组施法（T4b 快捷入口）：返回 {accepted, reject_reason, actions, consumed, spirit_after, ...}
    Dictionary cast_group(const String &p_group_id);

    // M1-03：真法器牌堆施法（完整 C-VM CastRequest：真游标/成文与散符/禁符反噬/幻影符）
    Dictionary cast_deck(const Dictionary &p_wand, const Dictionary &p_state = Dictionary(),
                         const Dictionary &p_rng = Dictionary());

    // M1-03：导出全部已加载符卡元数据供组装 UI 使用
    Array get_all_cards() const;

protected:
    static void _bind_methods();
};

}  // namespace godot

#endif  // GDSIM_VM_NODE_H
