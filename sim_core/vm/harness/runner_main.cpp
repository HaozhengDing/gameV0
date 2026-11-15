#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "compare.h"
#include "json_lite.h"
#include "json_util.h"
#include "vm/talisman_vm.h"

namespace {

// spec §6.4 覆盖矩阵：30 条用例。
constexpr int kExpectedCaseCount = 30;

std::string dump_string_list(const std::vector<std::string>& values) {
    std::string text = "[";
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) text += ", ";
        text += values[index];
    }
    text += "]";
    return text;
}

std::string dump_actions(const std::vector<vm::Value>& actions) {
    std::string text = "[";
    for (std::size_t index = 0; index < actions.size(); ++index) {
        if (index != 0) text += ", ";
        text += vmtest::dump_value(actions[index]);
    }
    text += "]";
    return text;
}

bool json_is_null(const simcore::json::Value& value) { return value.type == simcore::json::Value::NUL; }

bool numbers_equal(double expected, double actual) {
    const double scale = std::max({1.0, std::fabs(expected), std::fabs(actual)});
    return std::fabs(expected - actual) <= 1e-9 * scale;
}

std::string format_number(double number) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.15g", number);
    return std::string(buffer);
}

void compare_number_field(const simcore::json::Value& expect, const char* key, double actual,
                          std::vector<std::string>* errors) {
    const simcore::json::Value* value = expect.find(key);
    if (value == nullptr || !value->is_number()) {
        errors->push_back(std::string(key) + ": 期望字段缺失或不是数字");
        return;
    }
    if (!numbers_equal(value->number, actual)) {
        errors->push_back(std::string(key) + ": 期望 " + format_number(value->number) + "，实际 " +
                          format_number(actual));
    }
}

void compare_int_field(const simcore::json::Value& expect, const char* key, long long actual,
                       std::vector<std::string>* errors) {
    const simcore::json::Value* value = expect.find(key);
    if (value == nullptr || !value->is_number()) {
        errors->push_back(std::string(key) + ": 期望字段缺失或不是数字");
        return;
    }
    const long long expected = static_cast<long long>(value->number);
    if (expected != actual) {
        errors->push_back(std::string(key) + ": 期望 " + std::to_string(expected) + "，实际 " +
                          std::to_string(actual));
    }
}

void compare_bool_field(const simcore::json::Value& expect, const char* key, bool actual,
                        std::vector<std::string>* errors) {
    const simcore::json::Value* value = expect.find(key);
    if (value == nullptr || !value->is_bool()) {
        errors->push_back(std::string(key) + ": 期望字段缺失或不是 bool");
        return;
    }
    if (value->boolean != actual) {
        errors->push_back(std::string(key) + ": 期望 " + (value->boolean ? "true" : "false") + "，实际 " +
                          (actual ? "true" : "false"));
    }
}

void compare_int_array_field(const simcore::json::Value& expect, const char* key,
                             const std::vector<int>& actual, std::vector<std::string>* errors) {
    const simcore::json::Value* value = expect.find(key);
    if (value == nullptr || !value->is_array()) {
        errors->push_back(std::string(key) + ": 期望字段缺失或不是数组");
        return;
    }
    bool same = value->arr.size() == actual.size();
    if (same) {
        for (std::size_t index = 0; index < actual.size(); ++index) {
            const simcore::json::Value& item = value->arr[index];
            if (!item.is_number() || static_cast<int>(item.number) != actual[index]) {
                same = false;
                break;
            }
        }
    }
    if (!same) {
        std::string expected_text = "[";
        for (std::size_t index = 0; index < value->arr.size(); ++index) {
            if (index != 0) expected_text += ", ";
            expected_text += format_number(value->arr[index].number);
        }
        expected_text += "]";
        std::string actual_text = "[";
        for (std::size_t index = 0; index < actual.size(); ++index) {
            if (index != 0) actual_text += ", ";
            actual_text += std::to_string(actual[index]);
        }
        actual_text += "]";
        errors->push_back(std::string(key) + ": 期望 " + expected_text + "，实际 " + actual_text);
    }
}

void compare_event_codes(const simcore::json::Value& expect, const vm::CastResult& result,
                         std::vector<std::string>* errors) {
    const simcore::json::Value* value = expect.find("event_codes");
    if (value == nullptr || !value->is_array()) {
        errors->push_back("event_codes: 期望字段缺失或不是数组");
        return;
    }
    std::vector<std::string> expected;
    for (const simcore::json::Value& item : value->arr) {
        if (item.is_string()) expected.push_back(item.str);
    }
    std::vector<std::string> actual;
    actual.reserve(result.events.size());
    for (const vm::Event& event : result.events) actual.push_back(event.code);
    if (expected != actual) {
        errors->push_back("event_codes: 期望 " + dump_string_list(expected) + "，实际 " +
                          dump_string_list(actual));
    }
}

void compare_summary(const simcore::json::Value& summary, const vm::CastResult& result,
                     std::vector<std::string>* errors) {
    if (!summary.is_object()) {
        errors->push_back("expect.summary 不是对象");
        return;
    }
    compare_int_field(summary, "action_count", result.action_count, errors);
    compare_int_field(summary, "spawn_count", result.spawn_count, errors);
    compare_int_field(summary, "max_depth", result.max_depth, errors);
}

std::vector<std::string> compare_expectations(const simcore::json::Value& case_document,
                                              const vm::CastRequest& request,
                                              const vm::CastResult& result,
                                              const vm::CardCatalog& catalog) {
    std::vector<std::string> errors;
    const simcore::json::Value& expect = vmtest::require_member(case_document, "expect");

    // accepted / reject_reason（§4.2）
    const simcore::json::Value* expected_accepted = expect.find("accepted");
    const bool accepted = expected_accepted != nullptr && expected_accepted->boolean;
    if (accepted != result.accepted) {
        errors.push_back(std::string("accepted: 期望 ") + (accepted ? "true" : "false") + "，实际 " +
                         (result.accepted ? "true" : "false"));
    }
    const simcore::json::Value* expected_reject = expect.find("reject_reason");
    const bool reject_is_null = expected_reject == nullptr || json_is_null(*expected_reject);
    if (reject_is_null) {
        if (!result.reject_reason.empty()) {
            errors.push_back("reject_reason: 期望 null，实际 \"" + result.reject_reason + "\"");
        }
    } else if (!expected_reject->is_string()) {
        errors.push_back("reject_reason: 期望字段不是字符串");
    } else if (result.reject_reason != expected_reject->str) {
        errors.push_back("reject_reason: 期望 \"" + expected_reject->str + "\"，实际 \"" + result.reject_reason +
                         "\"");
    }

    // actions 或 summary（§6.2：二选一）
    const simcore::json::Value* expected_actions = expect.find("actions");
    if (expected_actions != nullptr && !json_is_null(*expected_actions)) {
        const std::vector<std::string> action_errors = vmtest::compare_actions(*expected_actions, result.actions);
        errors.insert(errors.end(), action_errors.begin(), action_errors.end());
        if (!action_errors.empty()) errors.push_back("实际 actions = " + dump_actions(result.actions));
    } else {
        const simcore::json::Value* summary = expect.find("summary");
        if (summary == nullptr) {
            errors.push_back("expect 需要 actions 或 summary");
        } else {
            compare_summary(*summary, result, &errors);
        }
    }

    // consumed（§6.3 第 3 条：严格有序相等）
    const simcore::json::Value* expected_consumed = expect.find("consumed");
    if (expected_consumed == nullptr || !expected_consumed->is_array()) {
        errors.push_back("consumed: 期望字段缺失或不是数组");
    } else {
        std::vector<std::string> expected_ids;
        for (const simcore::json::Value& item : expected_consumed->arr) {
            if (item.is_string()) expected_ids.push_back(item.str);
        }
        if (expected_ids != result.consumed) {
            errors.push_back("consumed: 期望 " + dump_string_list(expected_ids) + "，实际 " +
                             dump_string_list(result.consumed));
        }
    }

    // 施法后状态（§4.2）
    compare_number_field(expect, "spirit_after", result.spirit_after, &errors);
    compare_int_field(expect, "sanity_after", result.sanity_after, &errors);
    compare_bool_field(expect, "backlash_after", result.backlash_after, &errors);
    compare_int_array_field(expect, "phantom_slots_after", result.phantom_slots_after, &errors);
    compare_int_field(expect, "cursor_after", result.cursor_after, &errors);
    compare_bool_field(expect, "round_ended", result.round_ended, &errors);
    compare_int_field(expect, "ready_at_tick_after", result.ready_at_tick_after, &errors);

    // 事件码有序全等（§6.3 第 2 条）
    compare_event_codes(expect, result, &errors);

    // 不变量表达式（§6.3 第 4 条）+ §2.7 I1–I6 全局不变量（§6.3 第 5 条）
    const simcore::json::Value* invariants = expect.find("invariants");
    if (invariants == nullptr) {
        errors.push_back("invariants: 期望字段缺失");
    } else {
        const std::vector<std::string> invariant_errors =
            vmtest::check_invariant_expressions(*invariants, result);
        errors.insert(errors.end(), invariant_errors.begin(), invariant_errors.end());
    }
    const std::vector<std::string> global_errors = vmtest::check_global_invariants(request, result, catalog);
    errors.insert(errors.end(), global_errors.begin(), global_errors.end());

    return errors;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s <cases.json>\n", argv[0]);
        return 2;
    }
    simcore::json::Value document;
    std::string error;
    if (!simcore::json::parse_file(argv[1], &document, &error)) {
        std::fprintf(stderr, "vm_cases_runner: 读取 %s 失败: %s\n", argv[1], error.c_str());
        return 2;
    }
    const simcore::json::Value* cards = document.find("cards");
    const simcore::json::Value* cases = document.find("cases");
    if (cards == nullptr || cases == nullptr || !cases->is_array()) {
        std::fprintf(stderr, "vm_cases_runner: cases JSON 缺 cards 或 cases 数组\n");
        return 2;
    }
    const vm::CardCatalog catalog = vmtest::build_card_catalog(*cards);
    int passed = 0;
    int failed = 0;
    for (const simcore::json::Value& case_document : cases->arr) {
        const std::string id = case_document.string_or("id", "?");
        const std::string title = case_document.string_or("title", "");
        const vm::CastRequest request = vmtest::build_cast_request(case_document);
        const vm::CastResult result = vm::cast(request, catalog);
        const std::vector<std::string> errors = compare_expectations(case_document, request, result, catalog);
        if (errors.empty()) {
            ++passed;
            std::printf("PASS %s  %s\n", id.c_str(), title.c_str());
        } else {
            ++failed;
            std::printf("FAIL %s  %s\n", id.c_str(), title.c_str());
            for (const std::string& text : errors) std::printf("  - %s\n", text.c_str());
        }
    }
    const int total = passed + failed;
    std::printf("\nvm_cases: %d/%d passed, %d failed\n", passed, total, failed);
    if (failed == 0 && total == kExpectedCaseCount) {
        std::printf("OK: %d/%d cases passed\n", passed, kExpectedCaseCount);
        return 0;
    }
    if (total != kExpectedCaseCount) {
        std::fprintf(stderr, "vm_cases: 用例数 %d != 期望 %d（spec §6.4 覆盖矩阵）\n", total, kExpectedCaseCount);
    }
    return 1;
}