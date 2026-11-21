#ifndef GDSIM_SIM_NODE_H
#define GDSIM_SIM_NODE_H

// SimWorldNode：C-SIM v3（sim_core/include/sim/c_sim.h）的 Godot 包装。
// 只暴露 C ABI；Godot 侧（GDScript/场景）不感知 sim_core 的 C++ 内部实现。
// 设计目的：sim_core 升级时，Godot 侧只依赖本类方法。

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/sprite2d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/string.hpp>

#include "sim/c_sim.h"

namespace godot {

class SimWorldNode : public Sprite2D {
    GDCLASS(SimWorldNode, Sprite2D)

    sim_world *world_ = nullptr;
    int32_t active_w_ = 0;
    int32_t active_h_ = 0;

public:
    SimWorldNode() = default;
    ~SimWorldNode() override = default;

    void _notification(int p_what);

    // 世界生命周期
    bool create_world(int32_t p_width, int32_t p_height, int64_t p_seed,
                      const String &p_materials_json_path = String());
    void destroy_world();
    bool has_world() const;

    // 模拟
    void step_tick();
    void step_ticks(int32_t p_count);
    void set_active_rect(int32_t p_x, int32_t p_y, int32_t p_w, int32_t p_h);
    Rect2i get_dirty_rect(bool p_clear = true);

    // 物质读写（GDScript 侧建测试关卡用）
    void set_cell(int32_t p_x, int32_t p_y, int32_t p_material);
    void set_cell_by_name(int32_t p_x, int32_t p_y, const String &p_material);
    int32_t get_cell(int32_t p_x, int32_t p_y) const;
    int32_t get_cell_aux(int32_t p_x, int32_t p_y) const;
    int32_t material_id(const String &p_name) const;
    int32_t dig(int32_t p_x, int32_t p_y, int32_t p_radius);

    // M1-12（C-SIM v3）：热冲击 + 反应事件轮询
    int32_t apply_heat_burst(int32_t p_x, int32_t p_y, int32_t p_radius, float p_heat_temp = 400.0f);
    Array poll_events(int32_t p_max_count = 256);
    String reaction_id_str(int32_t p_reaction_id) const;
    float get_material_ignition_temp(int32_t p_material) const;
    String get_sim_version() const;

    // 渲染：C-SIM 的 RGBA8 调试渲染 → Image/ImageTexture
    Ref<Image> render_image() const;
    void update_texture();

    // T4b：视口区域渲染（相机跟随用；只渲染当前可见的 480x270 区域）
    Ref<Image> render_region(int32_t p_x, int32_t p_y, int32_t p_w, int32_t p_h) const;
    void update_texture_region(int32_t p_x, int32_t p_y, int32_t p_w, int32_t p_h);
    void wake_rect(int32_t p_x, int32_t p_y, int32_t p_w, int32_t p_h);

    // T4b：角色移动/材质查询（GDScript 世界层用）
    bool is_solid(int32_t p_x, int32_t p_y) const;
    int32_t get_material_count() const;
    int32_t get_material_state(int32_t p_material) const;
    bool get_material_flammable(int32_t p_material) const;
    String get_material_display(int32_t p_material) const;
    String get_material_id_str(int32_t p_material) const;

    // 只读信息
    int32_t get_world_width() const;
    int32_t get_world_height() const;
    int64_t get_tick() const;
    String get_materials_source() const;
    int64_t get_state_hash() const;
    int32_t get_active_width() const;
    int32_t get_active_height() const;

protected:
    static void _bind_methods();
};

} // namespace godot

#endif // GDSIM_SIM_NODE_H
