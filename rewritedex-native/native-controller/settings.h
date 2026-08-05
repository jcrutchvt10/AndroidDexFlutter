#pragma once

#include <filesystem>

// Single typed settings schema. This replaces the legacy rewritedex.ini
// GetPrivateProfileIntW calls (main.cpp:211-224) so validation, defaults and
// the on-disk representation live in exactly one place. Values are clamped on
// load so a hand-edited or corrupt file can never push the controller into an
// out-of-range state.
struct HostSettings {
    int qualityProfile = 1;  // 0 = responsive, 1 = balanced, 2 = maximum quality
    int shortcutPreset = 0;  // 0 = Windows key, 1 = Ctrl+Alt, 2 = off
    int monitorIndex = 0;
    bool allMonitors = false;
    bool preferPhysicalDisplay = true;
    bool windowsNotifications = true;
    bool audioEnabled = false;
    // Agent-owned knobs are mirrored here so the host shell is the single
    // settings UI; the agent API (/settings, /wallpaper) remains authoritative
    // for applying them.
    bool darkTheme = false;
    int wallpaperIntervalMinutes = 30;  // 0 disables rotation
    int wallpaperDimPct = 0;            // 0..65

    // Loads from jsonPath. If no JSON file exists yet, legacy settings are
    // read from legacyIniPath (if present) and immediately persisted as JSON
    // so existing users keep their configuration.
    void load(const std::filesystem::path& jsonPath, const std::filesystem::path& legacyIniPath);
    bool save(const std::filesystem::path& jsonPath) const;
};
