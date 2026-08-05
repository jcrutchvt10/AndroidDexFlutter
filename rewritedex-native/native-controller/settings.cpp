#include "settings.h"

#include <windows.h>

#include <algorithm>
#include <fstream>

#include "json.h"

namespace {
int clampInt(int value, int minValue, int maxValue) {
    return std::clamp(value, minValue, maxValue);
}

int readIniInt(const std::filesystem::path& path, const wchar_t* key, int fallback) {
    return GetPrivateProfileIntW(L"RewriteDEX", key, fallback, path.c_str());
}

bool readIniBool(const std::filesystem::path& path, const wchar_t* key, bool fallback) {
    return GetPrivateProfileIntW(L"RewriteDEX", key, fallback ? 1 : 0, path.c_str()) != 0;
}
} // namespace

void HostSettings::load(const std::filesystem::path& jsonPath, const std::filesystem::path& legacyIniPath) {
    *this = HostSettings{};
    std::ifstream input(jsonPath, std::ios::binary);
    if (input) {
        const std::string text((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
        try {
            const json::Value root = json::parse(text);
            qualityProfile = clampInt(root.at("qualityProfile").integer(qualityProfile), 0, 2);
            shortcutPreset = clampInt(root.at("shortcutPreset").integer(shortcutPreset), 0, 2);
            monitorIndex = std::max(0, root.at("monitorIndex").integer(monitorIndex));
            allMonitors = root.at("allMonitors").boolean(allMonitors);
            preferPhysicalDisplay = root.at("preferPhysicalDisplay").boolean(preferPhysicalDisplay);
            windowsNotifications = root.at("windowsNotifications").boolean(windowsNotifications);
            audioEnabled = root.at("audioEnabled").boolean(audioEnabled);
            darkTheme = root.at("darkTheme").boolean(darkTheme);
            wallpaperIntervalMinutes =
                std::max(0, root.at("wallpaperIntervalMinutes").integer(wallpaperIntervalMinutes));
            wallpaperDimPct = clampInt(root.at("wallpaperDimPct").integer(wallpaperDimPct), 0, 65);
            return;
        } catch (...) {
            // A corrupt settings file falls through to legacy migration below.
        }
    }
    if (!legacyIniPath.empty() && std::filesystem::exists(legacyIniPath)) {
        qualityProfile = clampInt(readIniInt(legacyIniPath, L"Quality", qualityProfile), 0, 2);
        shortcutPreset = clampInt(readIniInt(legacyIniPath, L"Shortcuts", shortcutPreset), 0, 2);
        monitorIndex = std::max(0, readIniInt(legacyIniPath, L"Monitor", monitorIndex));
        allMonitors = readIniBool(legacyIniPath, L"AllMonitors", allMonitors);
        preferPhysicalDisplay = readIniBool(legacyIniPath, L"PhysicalHandoff", preferPhysicalDisplay);
        windowsNotifications = readIniBool(legacyIniPath, L"WindowsNotifications", windowsNotifications);
        audioEnabled = readIniBool(legacyIniPath, L"AudioEnabled", audioEnabled);
        save(jsonPath);
    }
}

bool HostSettings::save(const std::filesystem::path& jsonPath) const {
    std::error_code error;
    std::filesystem::create_directories(jsonPath.parent_path(), error);
    const std::filesystem::path temporary = jsonPath.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output << "{\"schema\":1"
           << ",\"qualityProfile\":" << qualityProfile
           << ",\"shortcutPreset\":" << shortcutPreset
           << ",\"monitorIndex\":" << monitorIndex
           << ",\"allMonitors\":" << (allMonitors ? "true" : "false")
           << ",\"preferPhysicalDisplay\":" << (preferPhysicalDisplay ? "true" : "false")
           << ",\"windowsNotifications\":" << (windowsNotifications ? "true" : "false")
           << ",\"audioEnabled\":" << (audioEnabled ? "true" : "false")
           << ",\"darkTheme\":" << (darkTheme ? "true" : "false")
           << ",\"wallpaperIntervalMinutes\":" << wallpaperIntervalMinutes
           << ",\"wallpaperDimPct\":" << wallpaperDimPct << "}";
    output.close();
    if (!output) return false;
    std::filesystem::rename(temporary, jsonPath, error);
    if (!error) return true;
    std::filesystem::remove(jsonPath, error);
    error.clear();
    std::filesystem::rename(temporary, jsonPath, error);
    return !error;
}
