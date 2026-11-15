#ifndef SIMCORE_JSON_LITE_H
#define SIMCORE_JSON_LITE_H

// 无第三方依赖的最小 JSON 读取器（只读，不做 schema 校验）。
// 用途：读 data/materials.json 的材质参数，避免为 sim_core 引入 JSON 库。
// 限制：不支持注释、不支持 NaN/Infinity、UTF-8 按字节透传、嵌套深度上限 64。

#include <string>
#include <utility>
#include <vector>

namespace simcore {
namespace json {

struct Value {
    enum Type { NUL, BOOL, NUMBER, STRING, ARRAY, OBJECT } type = NUL;
    bool boolean = false;
    double number = 0.0;
    std::string str;
    std::vector<Value> arr;
    std::vector<std::pair<std::string, Value>> obj;

    bool is_object() const { return type == OBJECT; }
    bool is_array() const { return type == ARRAY; }
    bool is_string() const { return type == STRING; }
    bool is_number() const { return type == NUMBER; }
    bool is_bool() const { return type == BOOL; }

    // 对象成员查找；不存在返回 nullptr。
    const Value* find(const char* key) const;
    // 便捷读取（类型不符返回 fallback）。
    double number_or(const char* key, double fallback) const;
    bool bool_or(const char* key, bool fallback) const;
    std::string string_or(const char* key, const std::string& fallback) const;
};

// 解析 JSON 文本。成功返回 true；失败返回 false 并写 error。
bool parse(const std::string& text, Value* out, std::string* error);
// 读文件并解析。
bool parse_file(const std::string& path, Value* out, std::string* error);

}  // namespace json
}  // namespace simcore

#endif  // SIMCORE_JSON_LITE_H
