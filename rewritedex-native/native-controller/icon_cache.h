#pragma once

#include <filesystem>
#include <functional>
#include <string>

// Host-side cache for app icons served by the agent
// (GET /api/v1/app-icons/{package}, recommendation 3.3). Icons are persisted
// as PNGs beside host-workspace.json so the visual shell's launcher can render
// grids without round-tripping the device on every build.
//
// The fetch callback is injected so this module stays independent of the
// transport/agent HTTP client (monolith decomposition, recommendation 3.8).
class HostIconCache {
public:
    using Fetcher = std::function<std::string(const std::string& packageName)>;

    HostIconCache(std::filesystem::path cacheDirectory, Fetcher fetcher);

    // Returns the path to a valid cached icon, fetching and persisting from the
    // agent on a miss. Empty when the agent cannot produce an icon.
    std::filesystem::path ensureIcon(const std::string& packageName);

    // Path the icon will use, whether or not it exists yet.
    std::filesystem::path pathFor(const std::string& packageName) const;

private:
    std::filesystem::path cacheDirectory_;
    Fetcher fetcher_;
};
