#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "sim_node.h"

using namespace godot;

void initialize_gdsim_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(SimWorldNode);
}

void uninitialize_gdsim_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
// Godot 4.4+ GDExtension 入口：第一个参数是 get_proc_address 函数指针（不再是 interface 结构体）。
GDExtensionBool GDE_EXPORT gdsim_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                              GDExtensionClassLibraryPtr p_library,
                                              GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_gdsim_module);
    init_obj.register_terminator(uninitialize_gdsim_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
