cmake_minimum_required(VERSION 3.22)
project(gdsim LANGUAGES CXX)

# sim_core 的 GDExtension 包装：不依赖引擎的 C-SIM（sim_core/include/sim/c_sim.h）
# 直接编译进本扩展；Godot 侧只看到 C ABI，不 include 任何 sim_core 的 C++ 内部头。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# MSVC 默认按系统代码页读源文件；sim_core 与本文档都含中文注释/字符串，必须显式 UTF-8
if(MSVC)
    add_compile_options(/utf-8)
endif()

if(NOT DEFINED GODOT_CPP_DIR)
    message(FATAL_ERROR "需要 -DGODOT_CPP_DIR=<godot-cpp 4.5 源码目录>（GODOTCPP_TARGET 由 build 脚本传入）")
endif()
if(NOT DEFINED SIM_CORE_DIR)
    set(SIM_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../sim_core")
endif()

# godot-cpp：由构建脚本传 -DGODOTCPP_TARGET=template_debug/template_release
add_subdirectory("${GODOT_CPP_DIR}" godot-cpp EXCLUDE_FROM_ALL)

# C-SIM 实现（只编译库需要的三个 .cpp；不引入 bench/tests，也不需要 zlib）
add_library(sim_core_embed STATIC
    "${SIM_CORE_DIR}/src/world.cpp"
    "${SIM_CORE_DIR}/src/materials.cpp"
    "${SIM_CORE_DIR}/src/json_lite.cpp"
)
target_include_directories(sim_core_embed
    PUBLIC  "${SIM_CORE_DIR}/include"
    PRIVATE "${SIM_CORE_DIR}/src"
)
set_target_properties(sim_core_embed PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(gdsim SHARED
    src/register_types.cpp
    src/sim_node.cpp
    src/card_data.cpp
    src/vm_node.cpp
    "${SIM_CORE_DIR}/vm/src/cast.cpp"
)
target_include_directories(gdsim PRIVATE
    "${SIM_CORE_DIR}/include"
    "${SIM_CORE_DIR}/src"
    "${SIM_CORE_DIR}/vm/include"
)
target_compile_options(gdsim PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/W3> $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra>)
target_link_libraries(gdsim PRIVATE godot-cpp sim_core_embed)
set_target_properties(gdsim PROPERTIES
    OUTPUT_NAME "gdsim"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)
