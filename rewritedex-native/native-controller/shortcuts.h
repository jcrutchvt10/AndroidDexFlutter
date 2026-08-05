#pragma once

#include <filesystem>
#include <string>
#include <vector>

// Data-driven keyboard shortcut map (recommendation 3.9). The fixed
// chord->command table that used to live in keyboardHookProc (main.cpp) is
// moved into an editable JSON file beside the exe; the controller reads it at
// startup and falls back to built-in defaults when absent or corrupt.
//
// The shortcut *prefix* (Windows key vs Ctrl+Alt vs off) is still selected by
// shortcutPreset; only the per-key command table is data-driven here.
struct ShortcutChord {
    int vkCode = 0;
    int command = 0;
    std::wstring label;  // human description for the help overlay / settings UI
};

class ShortcutMap {
public:
    void load(const std::filesystem::path& jsonPath);

    // Returns the WM_COMMAND id for a virtual key code, or 0 when unmapped.
    int commandFor(int vkCode) const;
    bool save(const std::filesystem::path& jsonPath) const;

    const std::vector<ShortcutChord>& chords() const { return chords_; }

    // All chords share the same label prefix ("Win+" / "Ctrl+Alt+") chosen by
    // the active shortcut preset.
    std::wstring labelFor(int vkCode, const std::wstring& prefix) const;

private:
    std::vector<ShortcutChord> chords_;
};
