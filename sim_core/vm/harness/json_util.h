#ifndef VM_HARNESS_JSON_UTIL_H
#define VM_HARNESS_JSON_UTIL_H

// 测试 harness 专用：把仓库内 src/json_lite 读出的 JSON 转成 VM 契约类型。
// 只被 harness 使用；VM 核心库（sim_vm）不依赖 JSON（§7.5 纯函数边界）。

#include <string>

#include "json_lite.h"
#include "vm/talisman_vm.h"

namespace vmtest {

// simcore::json::Value → vm::Value（递归；对象保持插入顺序）。
vm::Value from_json(const simcore::json::Value& value);

// 取必需成员；不存在时抛 std::runtime_error（用例 JSON 结构由 T1 用例自检保证）。
const simcore::json::Value& require_member(const simcore::json::Value& object, const char* key);

int int_field(const simcore::json::Value& object, const char* key);
double number_field(const simcore::json::Value& object, const char* key);
bool bool_field(const simcore::json::Value& object, const char* key);
std::string string_field(const simcore::json::Value& object, const char* key);

// 从 tests/vm_cases/cards.yaml 的 JSON 化结果构建只读卡表（§5.1）。
vm::CardCatalog build_card_catalog(const simcore::json::Value& cards_document);

// 从一条用例的 initial/input 构建 CastRequest（§6.2 / §4.1）。
vm::CastRequest build_cast_request(const simcore::json::Value& case_document);

}  // namespace vmtest

#endif  // VM_HARNESS_JSON_UTIL_H
