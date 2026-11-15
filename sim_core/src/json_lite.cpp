#include "json_lite.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>

namespace simcore {
namespace json {
namespace {

constexpr int kMaxDepth = 64;

struct Parser {
    const char* p = nullptr;
    const char* end = nullptr;
    std::string error;
    int depth = 0;

    bool fail(const char* msg) {
        if (error.empty()) {
            std::ostringstream os;
            os << msg << " at byte offset " << (p ? static_cast<long>(p - begin) : -1L);
            error = os.str();
        }
        return false;
    }

    void skip_ws() {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) ++p;
    }

    bool expect(char c) {
        skip_ws();
        if (p >= end || *p != c) {
            char buf[32];
            std::snprintf(buf, sizeof(buf), "expected '%c'", c);
            return fail(buf);
        }
        ++p;
        return true;
    }

    bool parse_string(std::string* out) {
        if (!expect('"')) return false;
        out->clear();
        while (p < end) {
            char c = *p++;
            if (c == '"') return true;
            if (c == '\\') {
                if (p >= end) return fail("bad escape");
                char e = *p++;
                switch (e) {
                    case '"': out->push_back('"'); break;
                    case '\\': out->push_back('\\'); break;
                    case '/': out->push_back('/'); break;
                    case 'b': out->push_back('\b'); break;
                    case 'f': out->push_back('\f'); break;
                    case 'n': out->push_back('\n'); break;
                    case 'r': out->push_back('\r'); break;
                    case 't': out->push_back('\t'); break;
                    case 'u': {
                        // 只保留 BMP 的 UTF-8 近似；data/ 里没有 emoji 级字符。
                        if (end - p < 4) return fail("bad \\u escape");
                        unsigned cp = 0;
                        for (int i = 0; i < 4; ++i) {
                            char h = p[i];
                            cp <<= 4;
                            if (h >= '0' && h <= '9') cp |= static_cast<unsigned>(h - '0');
                            else if (h >= 'a' && h <= 'f') cp |= static_cast<unsigned>(h - 'a' + 10);
                            else if (h >= 'A' && h <= 'F') cp |= static_cast<unsigned>(h - 'A' + 10);
                            else return fail("bad \\u digit");
                        }
                        p += 4;
                        if (cp < 0x80) {
                            out->push_back(static_cast<char>(cp));
                        } else if (cp < 0x800) {
                            out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
                            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                        } else {
                            out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
                            out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                        }
                        break;
                    }
                    default: return fail("unknown escape");
                }
            } else {
                if (static_cast<unsigned char>(c) < 0x20) return fail("control char in string");
                out->push_back(c);
            }
        }
        return fail("unterminated string");
    }

    bool parse_number(Value* v) {
        const char* start = p;
        if (p < end && (*p == '-' || *p == '+')) ++p;
        while (p < end && std::isdigit(static_cast<unsigned char>(*p))) ++p;
        if (p < end && *p == '.') {
            ++p;
            while (p < end && std::isdigit(static_cast<unsigned char>(*p))) ++p;
        }
        if (p < end && (*p == 'e' || *p == 'E')) {
            ++p;
            if (p < end && (*p == '-' || *p == '+')) ++p;
            while (p < end && std::isdigit(static_cast<unsigned char>(*p))) ++p;
        }
        if (p == start) return fail("bad number");
        std::string tmp(start, p);
        char* endptr = nullptr;
        double d = std::strtod(tmp.c_str(), &endptr);
        if (endptr == tmp.c_str()) return fail("bad number");
        v->type = Value::NUMBER;
        v->number = d;
        return true;
    }

    bool parse_value(Value* v) {
        if (++depth > kMaxDepth) return fail("nesting too deep");
        skip_ws();
        if (p >= end) return fail("unexpected end of input");
        bool ok = false;
        switch (*p) {
            case 'n':
                if (end - p >= 4 && std::strncmp(p, "null", 4) == 0) { p += 4; v->type = Value::NUL; ok = true; }
                else return fail("bad literal");
                break;
            case 't':
                if (end - p >= 4 && std::strncmp(p, "true", 4) == 0) { p += 4; v->type = Value::BOOL; v->boolean = true; ok = true; }
                else return fail("bad literal");
                break;
            case 'f':
                if (end - p >= 5 && std::strncmp(p, "false", 5) == 0) { p += 5; v->type = Value::BOOL; v->boolean = false; ok = true; }
                else return fail("bad literal");
                break;
            case '"':
                v->type = Value::STRING;
                ok = parse_string(&v->str);
                break;
            case '[': {
                ++p;
                v->type = Value::ARRAY;
                skip_ws();
                if (p < end && *p == ']') { ++p; ok = true; break; }
                while (true) {
                    Value child;
                    if (!parse_value(&child)) { --depth; return false; }
                    v->arr.push_back(std::move(child));
                    skip_ws();
                    if (p >= end) { --depth; return fail("unterminated array"); }
                    if (*p == ',') { ++p; continue; }
                    if (*p == ']') { ++p; ok = true; break; }
                    --depth;
                    return fail("expected ',' or ']'");
                }
                break;
            }
            case '{': {
                ++p;
                v->type = Value::OBJECT;
                skip_ws();
                if (p < end && *p == '}') { ++p; ok = true; break; }
                while (true) {
                    skip_ws();
                    std::string key;
                    if (!parse_string(&key)) { --depth; return false; }
                    if (!expect(':')) { --depth; return false; }
                    Value child;
                    if (!parse_value(&child)) { --depth; return false; }
                    v->obj.emplace_back(std::move(key), std::move(child));
                    skip_ws();
                    if (p >= end) { --depth; return fail("unterminated object"); }
                    if (*p == ',') { ++p; continue; }
                    if (*p == '}') { ++p; ok = true; break; }
                    --depth;
                    return fail("expected ',' or '}'");
                }
                break;
            }
            default:
                v->type = Value::NUMBER;
                ok = parse_number(v);
                break;
        }
        --depth;
        if (!ok) return false;
        return true;
    }

    const char* begin = nullptr;
};

}  // namespace

const Value* Value::find(const char* key) const {
    if (type != OBJECT || key == nullptr) return nullptr;
    for (const auto& kv : obj) {
        if (kv.first == key) return &kv.second;
    }
    return nullptr;
}

double Value::number_or(const char* key, double fallback) const {
    const Value* v = find(key);
    if (v == nullptr || !v->is_number()) return fallback;
    return v->number;
}

bool Value::bool_or(const char* key, bool fallback) const {
    const Value* v = find(key);
    if (v == nullptr || !v->is_bool()) return fallback;
    return v->boolean;
}

std::string Value::string_or(const char* key, const std::string& fallback) const {
    const Value* v = find(key);
    if (v == nullptr || !v->is_string()) return fallback;
    return v->str;
}

bool parse(const std::string& text, Value* out, std::string* error) {
    if (out == nullptr) {
        if (error) *error = "null output";
        return false;
    }
    Parser parser;
    parser.begin = text.data();
    parser.p = text.data();
    parser.end = text.data() + text.size();
    out->type = Value::NUL;
    if (!parser.parse_value(out)) {
        if (error) *error = parser.error;
        return false;
    }
    parser.skip_ws();
    if (parser.p != parser.end) {
        if (error) *error = "trailing data after JSON value";
        return false;
    }
    return true;
}

bool parse_file(const std::string& path, Value* out, std::string* error) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        if (error) *error = "cannot open file: " + path;
        return false;
    }
    std::ostringstream os;
    os << f.rdbuf();
    if (!f.good() && !f.eof()) {
        if (error) *error = "read error: " + path;
        return false;
    }
    return parse(os.str(), out, error);
}

}  // namespace json
}  // namespace simcore
