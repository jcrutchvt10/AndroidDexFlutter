#pragma once

#include <filesystem>
#include <string>
#include <vector>

// Windows is the durable owner of the user's desktop identity.  The Android
// agent may remember a last-known freeform bound, but pinned/recent apps and
// the selected workspace deliberately live beside the Windows controller.
class HostWorkspaceState {
public:
    explicit HostWorkspaceState(std::filesystem::path path);

    void load();
    bool save() const;

    const std::vector<std::string>& pinnedApps() const { return pinnedApps_; }
    const std::vector<std::string>& recentApps() const { return recentApps_; }
    const std::string& selectedWorkspace() const { return selectedWorkspace_; }

    bool isPinned(const std::string& packageName) const;
    void togglePinned(const std::string& packageName);
    void recordLaunch(const std::string& packageName);
    void selectWorkspace(const std::string& name);

private:
    std::filesystem::path path_;
    std::vector<std::string> pinnedApps_;
    std::vector<std::string> recentApps_;
    std::string selectedWorkspace_ = "Desktop";
};
