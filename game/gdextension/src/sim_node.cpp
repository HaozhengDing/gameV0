#include "sim_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

using namespace godot;

void SimWorldNode::_bind_methods() {
    ClassDB::bind_method(D_METHOD("create_world", "width", "height", "seed", "materials_json_path"),
                         &SimWorldNode::create_world, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("destroy_world"), &SimWorldNode::destroy_world);
    ClassDB::bind_method(D_METHOD("has_world"), &SimWorldNode::has_world);

    ClassDB::bind_method(D_METHOD("step_tick"), &SimWorldNode::step_tick);
    ClassDB::bind_method(D_METHOD("step_ticks", "count"), &SimWorldNode::step_ticks);
    ClassDB::bind_method(D_METHOD("set_active_rect", "x", "y", "w", "h"), &SimWorldNode::set_active_rect);
    ClassDB::bind_method(D_METHOD("get_dirty_rect", "clear"), &SimWorldNode::get_dirty_rect, DEFVAL(true));

    ClassDB::bind_method(D_METHOD("set_cell", "x", "y", "material"), &SimWorldNode::set_cell);
    ClassDB::bind_method(D_METHOD("set_cell_by_name", "x", "y", "material"), &SimWorldNode::set_cell_by_name);
    ClassDB::bind_method(D_METHOD("get_cell", "x", "y"), &SimWorldNode::get_cell);
    ClassDB::bind_method(D_METHOD("material_id", "name"), &SimWorldNode::material_id);
    ClassDB::bind_method(D_METHOD("dig", "x", "y", "radius"), &SimWorldNode::dig);

    ClassDB::bind_method(D_METHOD("render_image"), &SimWorldNode::render_image);
    ClassDB::bind_method(D_METHOD("update_texture"), &SimWorldNode::update_texture);

    ClassDB::bind_method(D_METHOD("get_world_width"), &SimWorldNode::get_world_width);
    ClassDB::bind_method(D_METHOD("get_world_height"), &SimWorldNode::get_world_height);
    ClassDB::bind_method(D_METHOD("get_tick"), &SimWorldNode::get_tick);
    ClassDB::bind_method(D_METHOD("get_materials_source"), &SimWorldNode::get_materials_source);
    ClassDB::bind_method(D_METHOD("get_state_hash"), &SimWorldNode::get_state_hash);
    ClassDB::bind_method(D_METHOD("get_active_width"), &SimWorldNode::get_active_width);
    ClassDB::bind_method(D_METHOD("get_active_height"), &SimWorldNode::get_active_height);
}

void SimWorldNode::_notification(int p_what) {
    if (p_what == NOTIFICATION_PREDELETE) {
        destroy_world();
    }
}

bool SimWorldNode::create_world(int32_t p_width, int32_t p_height, int64_t p_seed,
                                const String &p_materials_json_path) {
    destroy_world();
    sim_config config{};
    config.width = static_cast<uint32_t>(p_width > 0 ? p_width : 1);
    config.height = static_cast<uint32_t>(p_height > 0 ? p_height : 1);
    config.seed = static_cast<uint64_t>(p_seed);
    config.chunk_size = SIM_CHUNK_SIZE;
    config.fixed_dt = 1.0f / 60.0f;
    CharString path_utf8 = p_materials_json_path.utf8();
    config.materials_json_path = path_utf8.length() > 0 ? path_utf8.get_data() : nullptr;
    world_ = sim_world_create(&config);
    if (world_ == nullptr) {
        ERR_PRINT("SimWorldNode: sim_world_create 失败");
        return false;
    }
    active_w_ = p_width;
    active_h_ = p_height;
    return true;
}

void SimWorldNode::destroy_world() {
    if (world_ != nullptr) {
        sim_world_destroy(world_);
        world_ = nullptr;
    }
    set_texture(Ref<Texture2D>());
}

bool SimWorldNode::has_world() const {
    return world_ != nullptr;
}

void SimWorldNode::step_tick() {
    ERR_FAIL_NULL(world_);
    sim_world_step(world_);
}

void SimWorldNode::step_ticks(int32_t p_count) {
    ERR_FAIL_NULL(world_);
    for (int32_t i = 0; i < p_count; ++i) {
        sim_world_step(world_);
    }
}

void SimWorldNode::set_active_rect(int32_t p_x, int32_t p_y, int32_t p_w, int32_t p_h) {
    ERR_FAIL_NULL(world_);
    sim_rect rect{p_x, p_y, p_w, p_h};
    sim_world_set_active_rect(world_, rect);
    active_w_ = p_w;
    active_h_ = p_h;
}

Rect2i SimWorldNode::get_dirty_rect(bool p_clear) {
    if (world_ == nullptr) {
        return Rect2i();
    }
    sim_rect rect = sim_world_dirty_rect(world_, p_clear ? 1 : 0);
    if (rect.w <= 0 || rect.h <= 0) {
        return Rect2i();
    }
    return Rect2i(rect.x, rect.y, rect.w, rect.h);
}

void SimWorldNode::set_cell(int32_t p_x, int32_t p_y, int32_t p_material) {
    ERR_FAIL_NULL(world_);
    if (p_material < 0 || p_material >= static_cast<int32_t>(SIM_MAT_COUNT_)) {
        ERR_PRINT("SimWorldNode.set_cell: 非法材质 id");
        return;
    }
    sim_world_set_cell(world_, p_x, p_y, static_cast<uint16_t>(p_material));
}

void SimWorldNode::set_cell_by_name(int32_t p_x, int32_t p_y, const String &p_material) {
    if (p_material.is_empty()) {
        set_cell(p_x, p_y, 0);
        return;
    }
    const int32_t id = material_id(p_material);
    if (id < 0) {
        ERR_PRINT("SimWorldNode.set_cell_by_name: 未知材质 " + p_material);
        return;
    }
    set_cell(p_x, p_y, id);
}

int32_t SimWorldNode::get_cell(int32_t p_x, int32_t p_y) const {
    if (world_ == nullptr) {
        return 0;
    }
    return static_cast<int32_t>(sim_world_get_cell(world_, p_x, p_y).material);
}

int32_t SimWorldNode::material_id(const String &p_name) const {
    if (world_ == nullptr) {
        return -1;
    }
    uint16_t id = sim_world_material_id_by_str(world_, p_name.utf8().get_data());
    return id == UINT16_MAX ? -1 : static_cast<int32_t>(id);
}

int32_t SimWorldNode::dig(int32_t p_x, int32_t p_y, int32_t p_radius) {
    ERR_FAIL_NULL_V(world_, 0);
    if (p_radius < 0) {
        return 0;
    }
    return static_cast<int32_t>(sim_world_dig(world_, p_x, p_y, static_cast<uint32_t>(p_radius)));
}

Ref<Image> SimWorldNode::render_image() const {
    ERR_FAIL_NULL_V(world_, Ref<Image>());
    const int32_t w = static_cast<int32_t>(sim_world_width(world_));
    const int32_t h = static_cast<int32_t>(sim_world_height(world_));
    PackedByteArray pixels;
    pixels.resize(static_cast<int64_t>(w) * h * 4);
    sim_rect rect{0, 0, w, h};
    const int rc = sim_world_render_rgba8(world_, rect, pixels.ptrw(),
                                          static_cast<size_t>(pixels.size()));
    if (rc != 0) {
        ERR_PRINT("SimWorldNode.render_image: sim_world_render_rgba8 失败");
        return Ref<Image>();
    }
    return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, pixels);
}

void SimWorldNode::update_texture() {
    Ref<Image> image = render_image();
    if (image.is_null()) {
        return;
    }
    Ref<ImageTexture> texture = get_texture();
    if (texture.is_null() || texture->get_width() != image->get_width() ||
        texture->get_height() != image->get_height()) {
        texture = ImageTexture::create_from_image(image);
        set_texture(texture);
    } else {
        texture->update(image);
    }
}

int32_t SimWorldNode::get_world_width() const {
    return world_ == nullptr ? 0 : static_cast<int32_t>(sim_world_width(world_));
}

int32_t SimWorldNode::get_world_height() const {
    return world_ == nullptr ? 0 : static_cast<int32_t>(sim_world_height(world_));
}

int64_t SimWorldNode::get_tick() const {
    return world_ == nullptr ? 0 : static_cast<int64_t>(sim_world_tick(world_));
}

String SimWorldNode::get_materials_source() const {
    return world_ == nullptr ? String() : String(sim_world_materials_source(world_));
}

int64_t SimWorldNode::get_state_hash() const {
    return world_ == nullptr ? 0 : static_cast<int64_t>(sim_world_hash(world_));
}

int32_t SimWorldNode::get_active_width() const {
    return active_w_;
}

int32_t SimWorldNode::get_active_height() const {
    return active_h_;
}
