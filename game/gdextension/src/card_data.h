#ifndef GDSIM_CARD_DATA_H
#define GDSIM_CARD_DATA_H

// 正式符卡数据（data/talismans.json）→ 符箓 VM 的只读卡表（C-VM）。
// 数据格式与 tests/vm_cases/cards.yaml 同构；两者重叠项由 tools/validate_data.py 交叉校验。

#include <string>
#include <vector>

#include "vm/talisman_vm.h"

namespace gdsim {

struct GroupDef {
    std::string id;
    std::string name;
    std::vector<std::string> segments;  // 按牌堆顺序：符头* 符胆 符脚*
    double spirit_cost = 0.0;
};

struct WandDefaults {
    double spirit = 80.0;
    double spirit_max = 80.0;
    double regen_per_sec = 10.0;
    int slots = 8;
    int sentences_per_cast = 1;
    int recharge_ticks = 30;
};

struct CardData {
    vm::CardCatalog catalog;
    std::vector<GroupDef> groups;
    WandDefaults wand;
    bool loaded = false;

    const GroupDef *find_group(const std::string &p_id) const;
};

// 读 data/talismans.json。失败返回 false 并写 error。
bool load_card_data(const std::string &p_path, CardData *r_data, std::string *r_error);

}  // namespace gdsim

#endif  // GDSIM_CARD_DATA_H
