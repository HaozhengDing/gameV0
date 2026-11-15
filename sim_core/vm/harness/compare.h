#ifndef VM_HARNESS_COMPARE_H
#define VM_HARNESS_COMPARE_H

// 用例比较逻辑（spec §6.2 / §6.3）：动作规范化后逐项深度相等（忽略 from）、
// 事件码有序全等、consumed 有序、状态字段、不变量表达式、§2.7 I1–I6 全局不变量。
// 只被 harness 使用，不进入 VM 核心库。

#include <string>
#include <vector>

#include "json_lite.h"
#include "vm/talisman_vm.h"

namespace vmtest {

// 期望动作（YAML→JSON）vs 实际动作：规范化（§3.2 默认值补齐、去 from）后逐项深度相等。
std::vector<std::string> compare_actions(const simcore::json::Value& expected_actions,
                                         const std::vector<vm::Value>& actual_actions);

// expect.invariants 字符串三元式求值（§6.3 第 4 条），返回所有不成立的断言。
std::vector<std::string> check_invariant_expressions(const simcore::json::Value& invariants,
                                                     const vm::CastResult& result);

// §2.7 的 I1–I6 全局不变量（每条用例隐式检查，§6.3 第 5 条）。
std::vector<std::string> check_global_invariants(const vm::CastRequest& request,
                                                 const vm::CastResult& result,
                                                 const vm::CardCatalog& catalog);

// 调试用：把 vm::Value 渲染成 JSON 风格文本（错误信息里使用）。
std::string dump_value(const vm::Value& value);

}  // namespace vmtest

#endif  // VM_HARNESS_COMPARE_H
