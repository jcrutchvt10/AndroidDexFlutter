#pragma once

#include <cctype>
#include <cstdlib>
#include <map>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

namespace json {
class Value {
public:
    using Array = std::vector<Value>;
    using Object = std::map<std::string, Value>;
    using Data = std::variant<std::nullptr_t, bool, double, std::string, Array, Object>;

    Value() : data_(nullptr) {}
    explicit Value(Data data) : data_(std::move(data)) {}
    bool is_object() const { return std::holds_alternative<Object>(data_); }
    bool is_array() const { return std::holds_alternative<Array>(data_); }
    const Object& object() const { return std::get<Object>(data_); }
    const Array& array() const { return std::get<Array>(data_); }
    std::string string(const std::string& fallback = {}) const {
        return std::holds_alternative<std::string>(data_) ? std::get<std::string>(data_) : fallback;
    }
    int integer(int fallback = 0) const {
        return std::holds_alternative<double>(data_) ? static_cast<int>(std::get<double>(data_)) : fallback;
    }
    long long integer64(long long fallback = 0) const {
        return std::holds_alternative<double>(data_) ? static_cast<long long>(std::get<double>(data_)) : fallback;
    }
    bool boolean(bool fallback = false) const {
        return std::holds_alternative<bool>(data_) ? std::get<bool>(data_) : fallback;
    }
    const Value& at(const std::string& key) const {
        static const Value empty;
        if (!is_object()) return empty;
        auto found = object().find(key);
        return found == object().end() ? empty : found->second;
    }

private:
    Data data_;
};

class Parser {
public:
    explicit Parser(const std::string& text) : text_(text) {}
    Value parse() {
        Value value = parse_value();
        whitespace();
        if (position_ != text_.size()) fail();
        return value;
    }

private:
    const std::string& text_;
    size_t position_ = 0;

    [[noreturn]] void fail() const { throw std::runtime_error("invalid JSON"); }
    void whitespace() { while (position_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[position_]))) ++position_; }
    bool consume(char value) { whitespace(); if (position_ < text_.size() && text_[position_] == value) { ++position_; return true; } return false; }
    void expect(const char* value) { while (*value) { if (position_ >= text_.size() || text_[position_++] != *value++) fail(); } }

    Value parse_value() {
        whitespace();
        if (position_ >= text_.size()) fail();
        switch (text_[position_]) {
        case '{': return Value(parse_object());
        case '[': return Value(parse_array());
        case '"': return Value(parse_string());
        case 't': expect("true"); return Value(true);
        case 'f': expect("false"); return Value(false);
        case 'n': expect("null"); return Value();
        default: return Value(parse_number());
        }
    }

    Value::Object parse_object() {
        if (!consume('{')) fail();
        Value::Object object;
        if (consume('}')) return object;
        do {
            whitespace();
            if (position_ >= text_.size() || text_[position_] != '"') fail();
            std::string key = parse_string();
            if (!consume(':')) fail();
            object.emplace(std::move(key), parse_value());
        } while (consume(','));
        if (!consume('}')) fail();
        return object;
    }

    Value::Array parse_array() {
        if (!consume('[')) fail();
        Value::Array array;
        if (consume(']')) return array;
        do { array.push_back(parse_value()); } while (consume(','));
        if (!consume(']')) fail();
        return array;
    }

    static void append_utf8(std::string& output, unsigned value) {
        if (value <= 0x7f) output.push_back(static_cast<char>(value));
        else if (value <= 0x7ff) { output.push_back(static_cast<char>(0xc0 | value >> 6)); output.push_back(static_cast<char>(0x80 | value & 0x3f)); }
        else { output.push_back(static_cast<char>(0xe0 | value >> 12)); output.push_back(static_cast<char>(0x80 | value >> 6 & 0x3f)); output.push_back(static_cast<char>(0x80 | value & 0x3f)); }
    }

    std::string parse_string() {
        if (!consume('"')) fail();
        std::string output;
        while (position_ < text_.size()) {
            char value = text_[position_++];
            if (value == '"') return output;
            if (value != '\\') { output.push_back(value); continue; }
            if (position_ >= text_.size()) fail();
            char escape = text_[position_++];
            switch (escape) {
            case '"': case '\\': case '/': output.push_back(escape); break;
            case 'b': output.push_back('\b'); break;
            case 'f': output.push_back('\f'); break;
            case 'n': output.push_back('\n'); break;
            case 'r': output.push_back('\r'); break;
            case 't': output.push_back('\t'); break;
            case 'u': {
                if (position_ + 4 > text_.size()) fail();
                unsigned code = 0;
                for (int i = 0; i < 4; ++i) {
                    char hex = text_[position_++];
                    code = code * 16 + (hex >= '0' && hex <= '9' ? hex - '0' : std::tolower(static_cast<unsigned char>(hex)) - 'a' + 10);
                }
                append_utf8(output, code);
                break;
            }
            default: fail();
            }
        }
        fail();
    }

    double parse_number() {
        whitespace();
        const char* start = text_.c_str() + position_;
        char* end = nullptr;
        double value = std::strtod(start, &end);
        if (end == start) fail();
        position_ += static_cast<size_t>(end - start);
        return value;
    }
};

inline Value parse(const std::string& text) { return Parser(text).parse(); }

inline std::string quote(const std::string& value) {
    std::string result = "\"";
    for (unsigned char c : value) {
        switch (c) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (c < 0x20) {
                constexpr char hex[] = "0123456789abcdef";
                result += "\\u00";
                result.push_back(hex[c >> 4]);
                result.push_back(hex[c & 0xf]);
            } else result.push_back(static_cast<char>(c));
        }
    }
    return result + "\"";
}
} // namespace json
