#include "shortcuts.h"

#include <windows.h>

#include <algorithm>
#include <fstream>

#include "json.h"

namespace {
constexpr int kCommandSnapLeft = 1011;
constexpr int kCommandSnapRight = 1012;
constexpr int kCommandMaximize = 1013;
constexpr int kCommandRestore = 1024;
constexpr int kCommandSmaller = 1025;
constexpr int kCommandLarger = 1026;
constexpr int kCommandCloseFocused = 1023;

void appendBuiltIn(std::vector<ShortcutChord>* chords) {
    chords->push_back({VK_LEFT, kCommandSnapLeft, L"Snap window left"});
    chords->push_back({VK_RIGHT, kCommandSnapRight, L"Snap window right"});
    chords->push_back({VK_UP, kCommandMaximize, L"Maximize window"});
    chords->push_back({VK_DOWN, kCommandRestore, L"Restore window"});
    chords->push_back({VK_OEM_PLUS, kCommandLarger, L"Grow window"});
    chords->push_back({VK_ADD, kCommandLarger, L"Grow window"});
    chords->push_back({VK_OEM_MINUS, kCommandSmaller, L"Shrink window"});
    chords->push_back({VK_SUBTRACT, kCommandSmaller, L"Shrink window"});
    chords->push_back({'W', kCommandCloseFocused, L"Close focused app"});
    chords->push_back({'Q', kCommandCloseFocused, L"Close focused app"});
}

std::wstring utf8ToWide(const std::string& value) {
    if (value.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (size <= 0) return {};
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
    return result;
}
} // namespace

void ShortcutMap::load(const std::filesystem::path& jsonPath) {
    chords_.clear();
    appendBuiltIn(&chords_);
    std::ifstream input(jsonPath, std::ios::binary);
    if (!input) return;
    const std::string text((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    try {
        const json::Value root = json::parse(text);
        const json::Value chords = root.at("chords");
        if (!chords.is_array()) return;
        std::vector<ShortcutChord> loaded;
        for (const json::Value& item : chords.array()) {
            const int vkCode = item.at("vk").integer(0);
            const int command = item.at("command").integer(0);
            if (vkCode <= 0 || command <= 0) continue;
            ShortcutChord chord;
            chord.vkCode = vkCode;
            chord.command = command;
            const std::string label = item.at("label").string();
            if (!label.empty()) chord.label = utf8ToWide(label);
            loaded.push_back(chord);
        }
        if (!loaded.empty()) chords_ = std::move(loaded);
    } catch (...) {
        // A corrupt shortcuts file must never break the desktop; keep defaults.
    }
}

int ShortcutMap::commandFor(int vkCode) const {
    for (const ShortcutChord& chord : chords_) {
        if (chord.vkCode == vkCode) return chord.command;
    }
    return 0;
}

std::wstring ShortcutMap::labelFor(int vkCode, const std::wstring& prefix) const {
    for (const ShortcutChord& chord : chords_) {
        if (chord.vkCode == vkCode) {
            std::wstring label = prefix;
            label += chord.label;
            return label;
        }
    }
    return {};
}

bool ShortcutMap::save(const std::filesystem::path& jsonPath) const {
    std::error_code error;
    std::filesystem::create_directories(jsonPath.parent_path(), error);
    const std::filesystem::path temporary = jsonPath.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output << "{\"schema\":1,\"chords\":[";
    for (size_t index = 0; index < chords_.size(); ++index) {
        if (index) output << ',';
        output << "{\"vk\":" << chords_[index].vkCode << ",\"command\":" << chords_[index].command << '}';
    }
    output << "]}";
    output.close();
    if (!output) return false;
    std::filesystem::rename(temporary, jsonPath, error);
    if (!error) return true;
    std::filesystem::remove(jsonPath, error);
    error.clear();
    std::filesystem::rename(temporary, jsonPath, error);
    return !error;
}
