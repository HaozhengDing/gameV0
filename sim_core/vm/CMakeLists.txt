# ---------------------------------------------------------------------------
# T3 参考符箓 VM（契约 C-VM / C-ACT）——纯函数 cast() + 30 条用例 harness。
# 由 sim_core/CMakeLists.txt 的 add_subdirectory(vm) hook 自动并入（§7.5）。
# 依赖方向：vm -> sim_core（只借用 src/json_lite 读用例 JSON），不得反向依赖。
# ---------------------------------------------------------------------------

# VM 核心库：只依赖 C++17 标准库（无 JSON、无第三方库）。
add_library(sim_vm STATIC
    src/cast.cpp
)
target_include_directories(sim_vm PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# 用例 harness：Python 把 YAML 转 JSON，C++ runner 用仓库内 json_lite 解析（只读）。
add_executable(vm_cases_runner
    harness/runner_main.cpp
    harness/json_util.cpp
    harness/compare.cpp
)
target_include_directories(vm_cases_runner PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/harness
    ${CMAKE_CURRENT_SOURCE_DIR}/../src   # sim_core/src/json_lite.h（只读复用）
)
target_link_libraries(vm_cases_runner PRIVATE sim_vm sim_core)

# C++ 边界测试（T3 复审修复 + spec §7.4.1 补写口径）；独立于 30 条契约用例。
add_executable(vm_edge_cases harness/edge_cases_main.cpp)
target_link_libraries(vm_edge_cases PRIVATE sim_vm)
add_test(NAME vm_edge_cases COMMAND vm_edge_cases)
set_tests_properties(vm_edge_cases PROPERTIES TIMEOUT 60)

# ctest：一条 vm_cases 测试跑完 T1 的 30 条用例（30/30 才算实验 B 通过，§7.5）。
find_package(Python3 COMPONENTS Interpreter REQUIRED)
add_test(NAME vm_cases
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/harness/run_cases.py
        --runner $<TARGET_FILE:vm_cases_runner>
        --repo-root ${CMAKE_CURRENT_SOURCE_DIR}/../..
        --work-dir ${CMAKE_CURRENT_BINARY_DIR}
)
set_tests_properties(vm_cases PROPERTIES TIMEOUT 180)