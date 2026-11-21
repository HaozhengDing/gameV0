#include "materials.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <system_error>

#include "json_lite.h"
#include "sim/c_sim.h"

namespace simcore {
namespace {

// 编译期默认值 = data/materials.json 2026-11-15 版本的快照（读不到 JSON 时用）。
// 沙 / 油 / 火不在 data/ 里，是 sim_core 的实验物质（任务 T2 要求）。
void add(std::vector<MatDef>* out, uint16_t id, const char* id_str, const char* display,
         uint8_t state, float density, uint32_t color, bool flammable, bool experimental) {
    MatDef d;
    d.id = id;
    d.id_str = id_str;
    d.display = display;
    d.state = state;
    d.density = density;
    d.color_rgb = color;
    d.flammable = flammable ? 1 : 0;
    d.experimental = experimental ? 1 : 0;
    out->push_back(std::move(d));
}

uint32_t parse_hex_color(const std::string& s, uint32_t fallback) {
    if (s.size() != 7 || s[0] != '#') return fallback;
    uint32_t v = 0;
    for (int i = 1; i < 7; ++i) {
        char c = s[static_cast<size_t>(i)];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
        else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
        else return fallback;
    }
    return v;
}

uint8_t parse_state(const std::string& s, uint8_t fallback) {
    if (s == "powder") return SIM_STATE_POWDER;
    if (s == "liquid") return SIM_STATE_LIQUID;
    if (s == "gas") return SIM_STATE_GAS;
    if (s == "solid") return SIM_STATE_STATIC;
    return fallback;
}

// 沿 extends 链浅合并：父项字段先放，子项覆盖同名字段。
void collect_fields(const json::Value& node, const std::map<std::string, const json::Value*>& by_id,
                    std::map<std::string, const json::Value*>* fields, int depth) {
    if (depth > 16) return;
    if (const json::Value* ext = node.find("extends")) {
        if (ext->is_string()) {
            auto it = by_id.find(ext->str);
            if (it != by_id.end()) collect_fields(*it->second, by_id, fields, depth + 1);
        }
    }
    if (!node.is_object()) return;
    for (const auto& kv : node.obj) {
        if (kv.first == "extends") continue;
        (*fields)[kv.first] = &kv.second;
    }
}

uint16_t parse_product(const std::string& s, uint16_t fallback) {
    if (s == "coal") return SIM_MAT_COAL;
    if (s == "smoke") return SIM_MAT_SMOKE;
    if (s == "toxic_smoke") return SIM_MAT_TOXIC_SMOKE;
    if (s == "steam") return SIM_MAT_STEAM;
    if (s == "water") return SIM_MAT_WATER;
    if (s == "empty") return SIM_MAT_EMPTY;
    return fallback;
}

// 用 JSON 字段覆盖一个 MatDef（C-SIM v3：额外消费 temperature / ignition_temperature / burn_time / burn_product）。
void apply_fields(const std::map<std::string, const json::Value*>& f, MatDef* d) {
    auto get = [&f](const char* key) -> const json::Value* {
        auto it = f.find(key);
        return it == f.end() ? nullptr : it->second;
    };
    if (const json::Value* v = get("density"); v && v->is_number()) d->density = static_cast<float>(v->number);
    if (const json::Value* v = get("state"); v && v->is_string()) d->state = parse_state(v->str, d->state);
    if (const json::Value* v = get("color"); v && v->is_string()) d->color_rgb = parse_hex_color(v->str, d->color_rgb);
    if (const json::Value* v = get("flammable"); v && v->is_bool()) d->flammable = v->boolean ? 1 : 0;
    if (const json::Value* v = get("name"); v && v->is_string()) d->display = v->str;
    if (const json::Value* v = get("id"); v && v->is_string()) d->id_str = v->str;
    if (const json::Value* v = get("temperature"); v && v->is_number()) d->temperature = static_cast<float>(v->number);
    if (const json::Value* v = get("ignition_temperature"); v && v->is_number()) {
        d->ignition_temp = static_cast<float>(v->number);
    }
    if (const json::Value* v = get("burn_time"); v && v->is_number() && v->number > 0.0) {
        const int bt = static_cast<int>(v->number);
        d->burn_time = static_cast<uint16_t>(bt > 255 ? 255 : bt);
    }
    if (const json::Value* v = get("burn_product"); v && v->is_string()) {
        d->burn_product = parse_product(v->str, d->burn_product);
    }
}

// 把 JSON 材质数组按 id 索引。
bool build_index(const json::Value& root, std::map<std::string, const json::Value*>* by_id,
                 std::string* error) {
    const json::Value* mats = root.find("materials");
    if (mats == nullptr || !mats->is_array()) {
        if (error) *error = "materials.json: missing array \"materials\"";
        return false;
    }
    for (const auto& m : mats->arr) {
        if (!m.is_object()) continue;
        const json::Value* id = m.find("id");
        if (id == nullptr || !id->is_string()) continue;
        (*by_id)[id->str] = &m;
    }
    return true;
}

void overlay(const std::map<std::string, const json::Value*>& by_id, const char* json_id,
             std::vector<MatDef>* defs, uint16_t mat_id) {
    auto it = by_id.find(json_id);
    if (it == by_id.end()) return;
    std::map<std::string, const json::Value*> fields;
    collect_fields(*it->second, by_id, &fields, 0);
    MatDef& d = (*defs)[mat_id];
    apply_fields(fields, &d);
    // experimental 标记：该物质来自 data/，所以覆盖后仍是「数据定义」。
    d.experimental = 0;
}

}  // namespace

void MaterialTable::init_builtin() {
    defs_.clear();
    defs_.reserve(SIM_MAT_COUNT_);
    // EMPTY 不是物质，占位以便按 id 直接索引。
    add(&defs_, SIM_MAT_EMPTY, "empty", "", SIM_STATE_EMPTY, 0.0f, 0x000000, false, true);
    // rock / water / quicksilver：参数会被 data/materials.json 覆盖（若可读到）。
    add(&defs_, SIM_MAT_ROCK, "rock", "岩", SIM_STATE_STATIC, 2.6f, 0x6B6258, false, false);
    add(&defs_, SIM_MAT_SAND, "sand", "沙", SIM_STATE_POWDER, 2.0f, 0xC9A85C, false, true);
    add(&defs_, SIM_MAT_WATER, "water", "水", SIM_STATE_LIQUID, 1.0f, 0x4A78C8, false, false);
    add(&defs_, SIM_MAT_OIL, "oil", "油", SIM_STATE_LIQUID, 0.9f, 0x6B4A22, true, true);
    add(&defs_, SIM_MAT_QUICKSILVER, "quicksilver", "水银", SIM_STATE_LIQUID, 13.6f, 0xB8C0C8, false, false);
    add(&defs_, SIM_MAT_FIRE, "fire", "火", SIM_STATE_GAS, 0.2f, 0xFF7A28, false, true);
    // C-SIM v2（T4b）：data/materials.json 的其余 9 种。参数会被 JSON 覆盖（若可读到）。
    add(&defs_, SIM_MAT_BLACK_DOG_BLOOD, "black_dog_blood", "黑狗血", SIM_STATE_LIQUID, 1.05f, 0x7A1F1F, false, false);
    add(&defs_, SIM_MAT_COAL, "coal", "煤", SIM_STATE_POWDER, 1.4f, 0x2B2B2B, true, false);
    add(&defs_, SIM_MAT_SALTPETER, "saltpeter", "硝石", SIM_STATE_POWDER, 2.1f, 0xD8D2C0, false, false);
    add(&defs_, SIM_MAT_SULFUR, "sulfur", "硫磺", SIM_STATE_POWDER, 2.0f, 0xD9C63A, true, false);
    add(&defs_, SIM_MAT_CINNABAR, "cinnabar", "朱砂", SIM_STATE_POWDER, 8.1f, 0xB23A2E, false, false);
    add(&defs_, SIM_MAT_LIME, "lime", "石灰", SIM_STATE_POWDER, 3.3f, 0xE8E2D0, false, false);
    add(&defs_, SIM_MAT_GLUTINOUS_RICE, "glutinous_rice", "糯米", SIM_STATE_POWDER, 0.8f, 0xF2EAD8, false, false);
    add(&defs_, SIM_MAT_BAMBOO, "bamboo", "竹木", SIM_STATE_STATIC, 0.7f, 0x8FA05A, true, false);
    add(&defs_, SIM_MAT_YIN_QI, "yin_qi", "阴气", SIM_STATE_GAS, 0.1f, 0x3A4A5A, false, false);
    // C-SIM v3（M1-12）：热/火与反应表二级气体材质（引擎内建，不占 data/materials.json 主表）。
    add(&defs_, SIM_MAT_SMOKE, "smoke", "烟", SIM_STATE_GAS, 0.15f, 0x4A4D52, false, true);
    add(&defs_, SIM_MAT_TOXIC_SMOKE, "toxic_smoke", "毒烟", SIM_STATE_GAS, 0.18f, 0x9AB834, false, true);
    add(&defs_, SIM_MAT_STEAM, "steam", "蒸汽", SIM_STATE_GAS, 0.12f, 0xD6E4EE, false, true);

    // 运动与燃烧参数（sim 内部默认值，可被 data/materials.json 覆盖）。
    defs_[SIM_MAT_SAND].spread = 1;
    defs_[SIM_MAT_WATER].spread = 3;
    defs_[SIM_MAT_OIL].spread = 3;
    defs_[SIM_MAT_QUICKSILVER].spread = 1; // 粘稠：横向找平慢
    defs_[SIM_MAT_BLACK_DOG_BLOOD].spread = 3;
    defs_[SIM_MAT_FIRE].fire_life_min = 40;
    defs_[SIM_MAT_FIRE].fire_life_max = 110;
    defs_[SIM_MAT_SMOKE].fire_life_min = 90;
    defs_[SIM_MAT_SMOKE].fire_life_max = 180;
    defs_[SIM_MAT_TOXIC_SMOKE].fire_life_min = 180;
    defs_[SIM_MAT_TOXIC_SMOKE].fire_life_max = 250;
    defs_[SIM_MAT_STEAM].fire_life_min = 80;
    defs_[SIM_MAT_STEAM].fire_life_max = 160;
    defs_[SIM_MAT_OIL].ignite_chance = 0.05f;
    defs_[SIM_MAT_OIL].ignition_temp = 150.0f;
    defs_[SIM_MAT_COAL].ignition_temp = 300.0f;
    defs_[SIM_MAT_COAL].burn_time = 180;
    defs_[SIM_MAT_COAL].burn_product = SIM_MAT_SMOKE;
    defs_[SIM_MAT_SULFUR].ignition_temp = 250.0f;
    defs_[SIM_MAT_SULFUR].burn_time = 90;
    defs_[SIM_MAT_SULFUR].burn_product = SIM_MAT_TOXIC_SMOKE;
    defs_[SIM_MAT_BAMBOO].ignition_temp = 200.0f;
    defs_[SIM_MAT_BAMBOO].burn_time = 120;
    defs_[SIM_MAT_BAMBOO].burn_product = SIM_MAT_COAL;
    defs_[SIM_MAT_YIN_QI].temperature = 10.0f;
}

bool MaterialTable::load(const char* json_path) {
    init_builtin();
    source_ = "builtin";
    warning_.clear();
    if (json_path == nullptr || json_path[0] == '\0') {
        warning_ = "no materials.json path given; using builtin defaults";
        return false;
    }
    json::Value root;
    std::string err;
    if (!json::parse_file(json_path, &root, &err)) {
        warning_ = std::string("cannot load materials.json (") + err + "); using builtin defaults";
        return false;
    }
    std::map<std::string, const json::Value*> by_id;
    if (!build_index(root, &by_id, &err)) {
        warning_ = err + "; using builtin defaults";
        return false;
    }
    // C-SIM v2：按 id_str 覆盖所有能从 data/materials.json 找到的物质（v1 只有 rock/water/quicksilver）
    for (size_t i = 1; i < defs_.size(); ++i) {
        overlay(by_id, defs_[i].id_str.c_str(), &defs_, static_cast<uint16_t>(i));
    }
    source_ = canonical_source(json_path);
    // 校验：密度必须 > 0，状态不能是 empty（防止数据写坏导致模拟异常）。
    for (const MatDef& d : defs_) {
        if (d.id == SIM_MAT_EMPTY) continue;
        if (!(d.density > 0.0f) || d.state == SIM_STATE_EMPTY) {
            warning_ = "materials.json produced invalid parameters for one material; kept builtin values";
            init_builtin();
            source_ = "builtin";
            return false;
        }
    }
    return true;
}

const MatDef* MaterialTable::find(uint16_t id) const {
    if (id >= defs_.size()) return nullptr;
    return &defs_[id];
}

std::string canonical_source(const std::string& path) {
    if (path.empty()) return "builtin";
    std::filesystem::path p(path);
    if (p.filename() == "materials.json" && p.has_parent_path() &&
        p.parent_path().filename() == "data") {
        return "data/materials.json";
    }
    return p.generic_string();
}

std::string find_materials_json(const char* argv0) {
    namespace fs = std::filesystem;
    if (const char* env = std::getenv("SIM_CORE_MATERIALS")) {
        if (env[0] != '\0') return std::string(env);
    }
    auto try_dir = [](const fs::path& dir) -> std::string {
        if (dir.empty()) return std::string();
        std::error_code ec;
        fs::path cand = dir / "data" / "materials.json";
        if (fs::is_regular_file(cand, ec) && !ec) return cand.string();
        cand = dir / "materials.json";
        if (fs::is_regular_file(cand, ec) && !ec) return cand.string();
        return std::string();
    };
    std::error_code ec;
    fs::path cwd = fs::current_path(ec);
    if (!ec) {
        fs::path dir = cwd;
        for (int i = 0; i < 6; ++i) {
            std::string found = try_dir(dir);
            if (!found.empty()) return found;
            if (!dir.has_parent_path() || dir.parent_path() == dir) break;
            dir = dir.parent_path();
        }
    }
    if (argv0 != nullptr && argv0[0] != '\0') {
        fs::path exe = fs::absolute(fs::path(argv0), ec);
        if (!ec) {
            fs::path dir = exe.parent_path();
            for (int i = 0; i < 6; ++i) {
                std::string found = try_dir(dir);
                if (!found.empty()) return found;
                if (!dir.has_parent_path() || dir.parent_path() == dir) break;
                dir = dir.parent_path();
            }
        }
    }
    return std::string();
}

}  // namespace simcore
