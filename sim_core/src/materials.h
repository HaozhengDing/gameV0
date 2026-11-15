#ifndef SIMCORE_MATERIALS_H
#define SIMCORE_MATERIALS_H

#include <cstdint>
#include <string>
#include <vector>

namespace simcore {

// 内部材质定义（含运动参数）。id 与 sim/c_sim.h 的 sim_material 一一对应。
struct MatDef {
    uint16_t id = 0;
    std::string id_str;   // 稳定字符串 id（data/materials.json 的 id 或 sim 内置名）
    std::string display;  // UTF-8 短名
    uint8_t state = 0;    // sim_state
    float density = 0.0f; // 水 = 1
    uint32_t color_rgb = 0;
    uint8_t flammable = 0;
    uint8_t experimental = 0; // 1 = sim_core 内定义，不在 data/ 里
    // --- 以下为 sim 内部运动参数，不暴露进 C-SIM ---
    uint8_t spread = 1;        // 液体每 tick 横向找平的最大步数
    uint8_t fire_life_min = 40;
    uint8_t fire_life_max = 110;
    float ignite_chance = 0.0f; // 被火点着的概率 / tick / 接触
};

// 材质表。默认全部为编译期默认值；load() 成功时用 data/materials.json
// 覆盖 water / quicksilver / rock 三个物质（沙、油、火为 sim 实验物质，数据在
// sim 内定义；其中油可燃、火寿命也是 sim 参数）。
class MaterialTable {
public:
    // 先填编译期默认值，再尝试读 json。json_path 为空 / 读失败 → 保留默认值。
    // 返回 true 表示成功读到 JSON。
    bool load(const char* json_path);

    const std::vector<MatDef>& defs() const { return defs_; }
    const std::string& source() const { return source_; }
    const std::string& warning() const { return warning_; }

    // 按 id 找定义（id 越界返回 nullptr）。
    const MatDef* find(uint16_t id) const;

private:
    void init_builtin();
    std::vector<MatDef> defs_;
    std::string source_ = "builtin";
    std::string warning_;
};

// 从可执行文件目录 / 当前工作目录向上找 data/materials.json。
// 环境变量 SIM_CORE_MATERIALS 优先。找不到返回空字符串。
std::string find_materials_json(const char* argv0);

// 材质来源的规范化短字符串："data/materials.json" 或 "builtin"。
std::string canonical_source(const std::string& path);

}  // namespace simcore

#endif  // SIMCORE_MATERIALS_H
