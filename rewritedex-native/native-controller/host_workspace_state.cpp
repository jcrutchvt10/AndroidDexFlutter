#include "host_workspace_state.h"

#include <algorithm>
#include <fstream>

#include "json.h"

namespace {
constexpr size_t kMaxRecentApps = 12;

void appendStringArray(const json::Value& value, std::vector<std::string>* target) {
    if (!value.is_array() || !target) return;
    for (const auto& item : value.array()) {
        const std::string packageName = item.string();
        if (!packageName.empty() && std::find(target->begin(), target->end(), packageName) == target->end()) {
            target->push_back(packageName);
        }
    }
}

std::string arrayJson(const std::vector<std::string>& values) {
    std::string result = "[";
    for (size_t index = 0; index < values.size(); ++index) {
        if (index) result += ',';
        result += json::quote(values[index]);
    }
    return result + ']';
}
} // namespace

HostWorkspaceState::HostWorkspaceState(std::filesystem::path path) : path_(std::move(path)) {}

void HostWorkspaceState::load() {
    pinnedApps_.clear();
    recentApps_.clear();
    selectedWorkspace_ = "Desktop";
    std::ifstream input(path_, std::ios::binary);
    if (!input) return;
    const std::string text((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    try {
        const json::Value root = json::parse(text);
        appendStringArray(root.at("pinnedApps"), &pinnedApps_);
        appendStringArray(root.at("recentApps"), &recentApps_);
        selectedWorkspace_ = root.at("selectedWorkspace").string("Desktop");
        if (selectedWorkspace_.empty()) selectedWorkspace_ = "Desktop";
    } catch (...) {
        // A corrupt host-state file must never block the USB desktop from starting.
    }
}

bool HostWorkspaceState::save() const {
    std::error_code error;
    std::filesystem::create_directories(path_.parent_path(), error);
    const std::filesystem::path temporary = path_.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output << "{\"schema\":1,\"pinnedApps\":" << arrayJson(pinnedApps_)
           << ",\"recentApps\":" << arrayJson(recentApps_)
           << ",\"selectedWorkspace\":" << json::quote(selectedWorkspace_) << "}";
    output.close();
    if (!output) return false;
    std::filesystem::rename(temporary, path_, error);
    if (!error) return true;
    std::filesystem::remove(path_, error);
    error.clear();
    std::filesystem::rename(temporary, path_, error);
    return !error;
}

bool HostWorkspaceState::isPinned(const std::string& packageName) const {
    return std::find(pinnedApps_.begin(), pinnedApps_.end(), packageName) != pinnedApps_.end();
}

void HostWorkspaceState::togglePinned(const std::string& packageName) {
    const auto found = std::find(pinnedApps_.begin(), pinnedApps_.end(), packageName);
    if (found != pinnedApps_.end()) pinnedApps_.erase(found);
    else if (!packageName.empty()) pinnedApps_.push_back(packageName);
}

void HostWorkspaceState::recordLaunch(const std::string& packageName) {
    if (packageName.empty()) return;
    recentApps_.erase(std::remove(recentApps_.begin(), recentApps_.end(), packageName), recentApps_.end());
    recentApps_.insert(recentApps_.begin(), packageName);
    if (recentApps_.size() > kMaxRecentApps) recentApps_.resize(kMaxRecentApps);
}

void HostWorkspaceState::selectWorkspace(const std::string& name) {
    if (!name.empty()) selectedWorkspace_ = name;
}
