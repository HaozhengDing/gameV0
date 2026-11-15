cmake_minimum_required(VERSION 3.20)
project(sim_core CXX)

# C++17 + CMake，不依赖任何引擎（T2 / D4 实验 A）。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 默认 Release：基准数据必须在优化下测。
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# ---------------------------------------------------------------------------
# 模拟库（公开头文件 include/sim/c_sim.h 即契约 C-SIM）
# ---------------------------------------------------------------------------
add_library(sim_core STATIC
    src/world.cpp
    src/materials.cpp
    src/json_lite.cpp
)
target_include_directories(sim_core
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_options(sim_core PRIVATE -Wall -Wextra)

# ---------------------------------------------------------------------------
# 基准程序（无界面；PNG 用 zlib，无其它第三方依赖）
# ---------------------------------------------------------------------------
find_package(ZLIB REQUIRED)
add_executable(sim_bench
    bench/bench_main.cpp
    bench/png_writer.cpp
)
target_include_directories(sim_bench PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/bench
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_options(sim_bench PRIVATE -Wall -Wextra)
target_link_libraries(sim_bench PRIVATE sim_core ZLIB::ZLIB)

# ---------------------------------------------------------------------------
# 测试（ctest）
# ---------------------------------------------------------------------------
enable_testing()
add_executable(sim_core_tests tests/test_main.cpp)
target_include_directories(sim_core_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_compile_options(sim_core_tests PRIVATE -Wall -Wextra)
target_link_libraries(sim_core_tests PRIVATE sim_core)

# data/materials.json 的路径由仓库相对位置推得；不存在时测试跳过材质来源断言。
set(SIM_MATERIALS_JSON "${CMAKE_CURRENT_SOURCE_DIR}/../data/materials.json")
if(EXISTS "${SIM_MATERIALS_JSON}")
    set(SIM_TEST_MATERIALS --materials "${SIM_MATERIALS_JSON}")
else()
    set(SIM_TEST_MATERIALS "")
endif()

add_test(NAME sim_determinism COMMAND sim_core_tests determinism ${SIM_TEST_MATERIALS})
add_test(NAME sim_dig COMMAND sim_core_tests dig ${SIM_TEST_MATERIALS})
add_test(NAME sim_conservation COMMAND sim_core_tests conservation ${SIM_TEST_MATERIALS})
add_test(NAME sim_api_contract COMMAND sim_core_tests api ${SIM_TEST_MATERIALS})
add_test(NAME sim_materials_json COMMAND sim_core_tests materials ${SIM_TEST_MATERIALS})
set_tests_properties(sim_determinism sim_dig sim_conservation sim_api_contract sim_materials_json
    PROPERTIES TIMEOUT 300)

# ---------------------------------------------------------------------------
# T3 的符箓 VM 模块（另一个任务提供）。目录存在时自动并入，不存在时构建不受影响。
# 契约：vm/CMakeLists.txt 允许依赖 sim_core target，但不得反向依赖。
# ---------------------------------------------------------------------------
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/vm/CMakeLists.txt)
    add_subdirectory(vm)
endif()
