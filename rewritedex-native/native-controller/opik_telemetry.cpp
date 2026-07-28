#include "opik_telemetry.h"

#include <windows.h>
#include <winhttp.h>
#include <objbase.h>

#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>
#include <string>
#include <thread>

#include "json.h"

namespace opik {
namespace {

constexpr char PROJECT_NAME[] = "rewritedex-agent";
constexpr char DEFAULT_URL[] = "https://www.comet.com/opik/api";

struct Config {
    std::string apiKey;
    std::string workspace;
    std::string url;
};

std::string environment(const char* name) {
    const DWORD required = GetEnvironmentVariableA(name, nullptr, 0);
    if (required == 0) return {};
    std::string value(required, '\0');
    const DWORD length = GetEnvironmentVariableA(name, value.data(), required);
    if (length == 0 || length >= required) return {};
    value.resize(length);
    return value;
}

const Config& config() {
    static const Config value = [] {
        Config result;
        result.apiKey = environment("OPIK_API_KEY");
        result.workspace = environment("OPIK_WORKSPACE");
        result.url = environment("OPIK_URL_OVERRIDE");
        if (result.url.empty()) result.url = DEFAULT_URL;
        return result;
    }();
    return value;
}

std::string uuid() {
    GUID value{};
    if (CoCreateGuid(&value) != S_OK) return {};
    wchar_t buffer[64]{};
    if (StringFromGUID2(value, buffer, static_cast<int>(sizeof(buffer) / sizeof(buffer[0]))) <= 0) {
        return {};
    }
    const int length = WideCharToMultiByte(CP_UTF8, 0, buffer, -1, nullptr, 0, nullptr, nullptr);
    if (length <= 1) return {};
    std::string result(length, '\0');
    WideCharToMultiByte(CP_UTF8, 0, buffer, -1, result.data(), length, nullptr, nullptr);
    result.resize(length - 1);
    if (!result.empty() && result.front() == '{') result.erase(result.begin());
    if (!result.empty() && result.back() == '}') result.pop_back();
    return result;
}

std::string timestamp(std::chrono::system_clock::time_point point) {
    const auto seconds = std::chrono::time_point_cast<std::chrono::seconds>(point);
    const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(point - seconds).count();
    const std::time_t raw = std::chrono::system_clock::to_time_t(seconds);
    std::tm utc{};
    gmtime_s(&utc, &raw);
    std::ostringstream output;
    output << std::put_time(&utc, "%Y-%m-%dT%H:%M:%S")
           << '.' << std::setw(3) << std::setfill('0') << millis << 'Z';
    return output.str();
}

bool sendTrace(
    const Config& settings,
    const std::string& method,
    const std::string& path,
    int statusCode,
    long long latencyMs) {
    URL_COMPONENTS components{};
    components.dwStructSize = sizeof(components);
    const std::wstring url(settings.url.begin(), settings.url.end());
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &components)) {
        return false;
    }

    const std::wstring host(components.lpszHostName, components.dwHostNameLength);
    std::wstring requestPath(components.lpszUrlPath, components.dwUrlPathLength);
    if (requestPath.empty()) requestPath = L"/";
    if (requestPath.back() != L'/') requestPath.push_back(L'/');
    requestPath += L"v1/private/traces";
    const auto end = std::chrono::system_clock::now();
    const auto start = end - std::chrono::milliseconds(latencyMs);
    const std::string traceId = uuid();
    if (traceId.empty()) return false;

    const std::string payload =
        "{\"id\":" + json::quote(traceId) +
        ",\"name\":\"agent-request\"" +
        ",\"project_name\":\"" + PROJECT_NAME + "\"" +
        ",\"start_time\":" + json::quote(timestamp(start)) +
        ",\"end_time\":" + json::quote(timestamp(end)) +
        ",\"input\":{\"method\":" + json::quote(method) +
        ",\"path\":" + json::quote(path) + "}" +
        ",\"output\":{\"status_code\":" + std::to_string(statusCode) +
        ",\"ok\":" + (statusCode >= 200 && statusCode < 300 ? "true" : "false") + "}" +
        ",\"metadata\":{\"latency_ms\":" + std::to_string(latencyMs) +
        ",\"component\":\"native-controller\"},\"tags\":[\"rewritedex\",\"android-agent\"]}";

    HINTERNET session = WinHttpOpen(
        L"RewriteDEX/Opik", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return false;
    WinHttpSetTimeouts(session, 500, 500, 500, 500);
    HINTERNET connection = WinHttpConnect(session, host.c_str(), components.nPort, 0);
    if (!connection) {
        WinHttpCloseHandle(session);
        return false;
    }
    const DWORD flags = components.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET request = WinHttpOpenRequest(
        connection, L"POST", requestPath.c_str(), nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return false;
    }

    const std::wstring headers =
        L"Content-Type: application/json\r\nAccept: application/json\r\n" +
        std::wstring(L"Comet-Workspace: ") +
        std::wstring(settings.workspace.begin(), settings.workspace.end()) + L"\r\n" +
        L"Authorization: " + std::wstring(settings.apiKey.begin(), settings.apiKey.end()) + L"\r\n";
    const BOOL sent = WinHttpSendRequest(
        request, headers.c_str(), static_cast<DWORD>(-1L),
        const_cast<char*>(payload.c_str()), static_cast<DWORD>(payload.size()),
        static_cast<DWORD>(payload.size()), 0);
    const BOOL received = sent && WinHttpReceiveResponse(request, nullptr);
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    return received == TRUE;
}

} // namespace

void trackAgentRequest(
    const std::string& method,
    const std::string& path,
    int statusCode,
    long long latencyMs) {
    // Pointer movement can generate hundreds of requests per minute and is
    // transport noise rather than useful agent behavior.
    if (path == "/desktop/input") return;
    const Config& settings = config();
    if (settings.apiKey.empty() || settings.workspace.empty()) return;
    std::thread([settings, method, path, statusCode, latencyMs] {
        sendTrace(settings, method, path, statusCode, latencyMs);
    }).detach();
}

} // namespace opik
