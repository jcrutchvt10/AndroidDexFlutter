#include "icon_cache.h"

#include <fstream>
#include <functional>

namespace {
bool looksLikePng(const std::string& bytes) {
    static constexpr unsigned char kPngSignature[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (bytes.size() < sizeof(kPngSignature)) return false;
    return std::equal(std::begin(kPngSignature), std::end(kPngSignature), bytes.begin());
}

bool isSafePackageName(const std::string& packageName) {
    if (packageName.empty() || packageName.size() > 128) return false;
    for (const unsigned char c : packageName) {
        const bool safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                          (c >= '0' && c <= '9') || c == '.' || c == '_';
        if (!safe) return false;
    }
    return true;
}

std::string readFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) return {};
    return std::string((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
}
} // namespace

HostIconCache::HostIconCache(std::filesystem::path cacheDirectory, Fetcher fetcher)
    : cacheDirectory_(std::move(cacheDirectory)), fetcher_(std::move(fetcher)) {}

std::filesystem::path HostIconCache::pathFor(const std::string& packageName) const {
    return cacheDirectory_ / (packageName + ".png");
}

std::filesystem::path HostIconCache::ensureIcon(const std::string& packageName) {
    if (!isSafePackageName(packageName)) return {};
    const std::filesystem::path iconPath = pathFor(packageName);
    std::error_code error;
    if (std::filesystem::is_regular_file(iconPath, error) && std::filesystem::file_size(iconPath, error) > 0) {
        return iconPath;
    }
    if (!fetcher_) return {};
    const std::string png = fetcher_(packageName);
    if (!looksLikePng(png)) return {};
    std::filesystem::create_directories(cacheDirectory_, error);
    const std::filesystem::path temporary = iconPath.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return {};
    output.write(png.data(), static_cast<std::streamsize>(png.size()));
    output.close();
    if (!output) return {};
    std::filesystem::rename(temporary, iconPath, error);
    if (error) return {};
    return iconPath;
}
