#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <shellscalingapi.h>
#include <shlobj.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cwctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "json.h"
#include "host_workspace_state.h"
#include "opik_telemetry.h"

namespace {
constexpr UINT WM_REFRESH_DEVICE = WM_APP + 1;
constexpr UINT WM_TRAY = WM_APP + 2;
constexpr UINT WM_DESKTOP_INPUT = WM_APP + 3;
constexpr UINT WM_HOST_EVENT = WM_APP + 4;
constexpr int ID_REFRESH = 1001;
constexpr int ID_DESKTOP = 1002;
constexpr int ID_SETTINGS = 1003;
constexpr int ID_NOTIFICATIONS = 1004;
constexpr int ID_QUICK_SETTINGS = 1005;
constexpr int ID_AUDIO_OUTPUT = 1006;
constexpr int ID_WALLPAPER_NEXT = 1007;
constexpr int ID_PHONE_CONTROL = 1008;
constexpr int ID_KEYBOARD_DESKTOP = 1009;
constexpr int ID_KEYBOARD_PHYSICAL = 1010;
constexpr int ID_SNAP_LEFT = 1011;
constexpr int ID_SNAP_RIGHT = 1012;
constexpr int ID_MAXIMIZE_TASK = 1013;
constexpr int ID_DIAGNOSTICS = 1014;
constexpr int ID_NOTIFICATION_ACCESS = 1015;
constexpr int ID_RECORDING = 1016;
constexpr int ID_SCREENSHOT = 1017;
constexpr int ID_OPEN_EXPORTS = 1018;
constexpr int ID_OPEN_LOGS = 1050;
constexpr int ID_EXPORT_DIAGNOSTICS = 1051;
constexpr int ID_SETTINGS_APPLY = 2001;
constexpr int ID_SETTINGS_CANCEL = 2002;
constexpr int ID_MONITOR_COMBO = 1052;
constexpr int ID_WINDOWS_NOTIFICATIONS = 1019;
constexpr int ID_DESKTOP_AUDIO = 1029;
constexpr int ID_HOST_LAUNCHER = 1036;
constexpr int ID_HOST_WORKSPACES = 1037;
constexpr int ID_FOCUS_DESKTOP = 1038;
constexpr int ID_AGENT_SETTINGS = 1033;
constexpr int ID_WIDGETS_SHOW = 1034;
constexpr int ID_WIDGETS_HIDE = 1035;
constexpr int ID_QUALITY_LOW = 1020;
constexpr int ID_QUALITY_BALANCED = 1021;
constexpr int ID_QUALITY_MAX = 1022;
constexpr int ID_CLOSE_FOCUSED_APP = 1023;
constexpr int ID_WINDOW_RESTORE = 1024;
constexpr int ID_WINDOW_SMALLER = 1025;
constexpr int ID_WINDOW_LARGER = 1026;
constexpr int ID_WINDOW_PHONE = 1027;
constexpr int ID_WINDOW_TABLET = 1028;
constexpr int ID_SHORTCUT_WINDOWS = 1030;
constexpr int ID_SHORTCUT_CTRL_ALT = 1031;
constexpr int ID_SHORTCUT_DISABLED = 1032;
constexpr int ID_MONITOR_SELECTED = 1040;
constexpr int ID_MONITOR_ALL = 1041;
constexpr int ID_PHYSICAL_HANDOFF = 1042;
constexpr int ID_TRAY_SHOW = 1101;
constexpr int ID_TRAY_START = 1102;
constexpr int ID_TRAY_QUIT = 1103;
constexpr int ID_TRAY_STOP = 1104;
constexpr UINT_PTR PROCESS_TIMER = 2001;
constexpr UINT_PTR SESSION_TIMER = 2002;
constexpr UINT_PTR EXPORT_TIMER = 2003;
constexpr UINT_PTR RECONNECT_TIMER = 2004;
constexpr int DYNAMIC_ID_FIRST = 4000;
constexpr int AGENT_PORT = 8792;
constexpr int TARGET_SHORT_SIDE_DP = 700;

// All mutable application state in one place.  Grouped by lifetime and access
// pattern to make future unit testing and parallelism easier.
struct RewriteDEXController {
    // Transport state
    std::wstring status = L"Looking for a connected Pixel...";
    std::wstring serial;
    std::string sessionToken;
    HWND window = nullptr;
    HWND scrcpyWindow = nullptr;
    DWORD scrcpyPid = 0;
    HANDLE scrcpyProcess = nullptr;
    HANDLE scrcpyJob = nullptr;
    HANDLE singleInstance = nullptr;
    HHOOK keyboardHook = nullptr;
    HHOOK mouseHook = nullptr;
    bool trayAdded = false;
    bool startDesktop = false;
    bool desktopRequested = false;
    bool restartingDesktop = false;
    bool recording = false;
    bool windowsNotifications = true;
    bool allMonitors = false;
    bool preferPhysicalDisplay = true;
    bool audioEnabled = false;  // default off for encoder/latency stability on long DeX sessions
    int qualityProfile = 1;
    int shortcutPreset = 0;
    int monitorIndex = 0;
    long long latestNotification = 0;
    bool notificationsInitialized = false;
    std::atomic<long long> hostEventCursor{0};
    std::atomic_bool hostEventPollInFlight{false};
    int primaryDisplayId = 0;
    int primaryDisplayWidth = 0;
    int primaryDisplayHeight = 0;
    // Virtual displays that existed before the current scrcpy session. The
    // Pixel can retain stale displays after a previous transport exits; never
    // bind the visible session to one of those old IDs.
    std::vector<int> launchBaselineVirtualDisplays;
    std::unique_ptr<HostWorkspaceState> hostWorkspace;
    UINT uiDpi = 96;
    // Throttle edge-resize move posts so the agent is not flooded.
    ULONGLONG lastDesktopMoveNotifyMs = 0;

    // Per-display transport windows
    struct ExtraTransport {
        HANDLE process = nullptr;
        DWORD pid = 0;
        HWND window = nullptr;
        int displayId = 0;
        int width = 0;
        int height = 0;
    };
    std::vector<ExtraTransport> extraTransports;

    // Independently managed HWNDs backed by the persistent rooted task
    // compositor. Each process is only a decoder/control relay; the Android
    // broker owns the organizer, leashes, mirrors and encoders.
    struct TaskSurfaceTransport {
        HANDLE process = nullptr;
        DWORD pid = 0;
        HWND window = nullptr;
        int taskId = -1;
        int displayId = 0;
    };
    std::vector<TaskSurfaceTransport> taskSurfaces;

    // Tray menu dynamic actions (menu items registered at runtime)
    struct DynamicAction {
        std::string method;
        std::string path;
        std::string body;
        std::wstring success;
        std::string launchedPackage;
        std::string selectedWorkspace;
    };
    std::unordered_map<int, DynamicAction> dynamicActions;
};
RewriteDEXController g_ctrl;

// Winsock is initialized once at startup and torn down at exit.  Avoids the
// per-request WSAStartup/WSACleanup overhead.
bool ensureWinsock() {
    static bool initialized = []{ WSADATA data; return WSAStartup(MAKEWORD(2,2),&data)==0; }();
    return initialized;
}

std::filesystem::path moduleDirectory();
std::filesystem::path settingsPath() {
    return moduleDirectory() / L"rewritedex.ini";
}

int scaleForDpi(int value, UINT dpi) {
    return MulDiv(value, static_cast<int>(dpi), 96);
}

std::wstring quote(const std::wstring& value) {
    return L"\"" + value + L"\"";
}

std::wstring utf8ToWide(const std::string& value) {
    if (value.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (size <= 0) return {};
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
    return result;
}

std::filesystem::path knownFolder(REFKNOWNFOLDERID id, const wchar_t* fallback) {
    PWSTR value = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_CREATE, nullptr, &value))) {
        std::filesystem::path result(value);
        CoTaskMemFree(value);
        return result;
    }
    return std::filesystem::path(fallback);
}

void saveSetting(const wchar_t* key, int value) {
    WritePrivateProfileStringW(L"RewriteDEX", key, std::to_wstring(value).c_str(), settingsPath().c_str());
}

void loadSettings() {
    const auto path = settingsPath();
    g_ctrl.qualityProfile = GetPrivateProfileIntW(L"RewriteDEX", L"Quality", 1, path.c_str());
    g_ctrl.shortcutPreset = GetPrivateProfileIntW(L"RewriteDEX", L"Shortcuts", 0, path.c_str());
    g_ctrl.monitorIndex = GetPrivateProfileIntW(L"RewriteDEX", L"Monitor", 0, path.c_str());
    g_ctrl.allMonitors = GetPrivateProfileIntW(L"RewriteDEX", L"AllMonitors", 0, path.c_str()) != 0;
    g_ctrl.preferPhysicalDisplay = GetPrivateProfileIntW(L"RewriteDEX", L"PhysicalHandoff", 1, path.c_str()) != 0;
    g_ctrl.windowsNotifications = GetPrivateProfileIntW(L"RewriteDEX", L"WindowsNotifications", 1, path.c_str()) != 0;
    g_ctrl.audioEnabled = GetPrivateProfileIntW(L"RewriteDEX", L"AudioEnabled", 0, path.c_str()) != 0;
}

std::string createSessionToken() {
    unsigned char bytes[32]{};
    if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        return {};
    }
    constexpr char hex[] = "0123456789abcdef";
    std::string token;
    token.reserve(64);
    for (const unsigned char byte : bytes) {
        token.push_back(hex[byte >> 4]);
        token.push_back(hex[byte & 0x0f]);
    }
    return token;
}

std::wstring runHidden(const std::wstring& command, DWORD timeoutMs = 7000) {
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
    HANDLE readPipe = nullptr;
    HANDLE writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &attributes, 0)) return {};
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW startup{sizeof(startup)};
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = writePipe;
    startup.hStdError = writePipe;
    PROCESS_INFORMATION process{};
    std::vector<wchar_t> buffer(command.begin(), command.end());
    buffer.push_back(L'\0');
    const BOOL started = CreateProcessW(
        nullptr, buffer.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
        nullptr, nullptr, &startup, &process);
    CloseHandle(writePipe);
    if (!started) {
        CloseHandle(readPipe);
        return {};
    }

    std::string output;
    const ULONGLONG deadline = GetTickCount64() + timeoutMs;
    bool running = true;
    while (running) {
        DWORD available = 0;
        while (PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr) && available > 0) {
            char bytes[4096];
            DWORD count = 0;
            const DWORD requested = std::min<DWORD>(available, sizeof(bytes));
            if (!ReadFile(readPipe, bytes, requested, &count, nullptr) || count == 0) break;
            if (output.size() < 2 * 1024 * 1024) {
                const size_t remaining = 2 * 1024 * 1024 - output.size();
                output.append(bytes, std::min<size_t>(count, remaining));
            }
            available -= std::min(available, count);
        }
        running = WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT;
        if (running && GetTickCount64() >= deadline) {
            TerminateProcess(process.hProcess, ERROR_TIMEOUT);
            WaitForSingleObject(process.hProcess, 1000);
            running = false;
        }
        if (running) Sleep(10);
    }
    DWORD available = 0;
    while (PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr) && available > 0) {
        char bytes[4096];
        DWORD count = 0;
        if (!ReadFile(readPipe, bytes, std::min<DWORD>(available, sizeof(bytes)), &count, nullptr) || count == 0) break;
        if (output.size() < 2 * 1024 * 1024) {
            const size_t remaining = 2 * 1024 * 1024 - output.size();
            output.append(bytes, std::min<size_t>(count, remaining));
        }
    }
    CloseHandle(readPipe);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);

    if (output.empty()) return {};
    const int size = MultiByteToWideChar(
        CP_UTF8, 0, output.data(), static_cast<int>(output.size()), nullptr, 0);
    if (size <= 0) return {};
    std::wstring result(size, L'\0');
    MultiByteToWideChar(
        CP_UTF8, 0, output.data(), static_cast<int>(output.size()), result.data(), size);
    return result;
}

std::filesystem::path moduleDirectory() {
    wchar_t modulePath[MAX_PATH]{};
    GetModuleFileNameW(nullptr, modulePath, MAX_PATH);
    return std::filesystem::path(modulePath).parent_path();
}

std::filesystem::path scrcpyForkPath() {
    const std::filesystem::path executable = moduleDirectory();
    const std::vector<std::filesystem::path> candidates{
        executable / L"scrcpy" / L"scrcpy-fork.exe",
        executable / L".." / L".." / L"third_party" / L"scrcpy" / L"scrcpy-fork.exe",
        executable / L".." / L"third_party" / L"scrcpy" / L"scrcpy-fork.exe",
    };
    for (const auto& candidate : candidates) {
        std::error_code error;
        if (std::filesystem::is_regular_file(candidate, error)) {
            return std::filesystem::weakly_canonical(candidate, error);
        }
    }
    return candidates.front();
}

std::wstring runAdb(const std::wstring& args, DWORD timeoutMs = 7000) {
    const std::filesystem::path adb = scrcpyForkPath().parent_path() / L"adb.exe";
    if (!std::filesystem::exists(adb)) return {};
    return runHidden(quote(adb.wstring()) + L" " + args, timeoutMs);
}

std::string agentRequest(
    const char* method, const char* path, const std::string& body = {}, DWORD timeoutMs = 5000) {
    const auto startedAt = std::chrono::steady_clock::now();
    auto finish = [&](std::string response, int statusCode) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - startedAt).count();
        opik::trackAgentRequest(method, path, statusCode, elapsed);
        return response;
    };
    if (!ensureWinsock()) return finish({}, 0);
    SOCKET connection = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (connection == INVALID_SOCKET) return finish({}, 0);

    DWORD timeout = timeoutMs;
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(AGENT_PORT);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(connection, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        closesocket(connection);
        return finish({}, 0);
    }

    std::ostringstream request;
    request << method << ' ' << path << " HTTP/1.1\r\n"
            << "Host: 127.0.0.1\r\n"
            << "X-RewriteDEX-Token: " << g_ctrl.sessionToken << "\r\n"
            << "Content-Type: application/json\r\n"
            << "Content-Length: " << body.size() << "\r\n"
            << "Connection: close\r\n\r\n"
            << body;
    const std::string outbound = request.str();
    size_t sent = 0;
    while (sent < outbound.size()) {
        const int count = send(
            connection, outbound.data() + sent,
            static_cast<int>(std::min<size_t>(outbound.size() - sent, INT_MAX)), 0);
        if (count <= 0) {
            closesocket(connection);
            return finish({}, 0);
        }
        sent += static_cast<size_t>(count);
    }

    std::string response;
    char chunk[2048];
    int received = 0;
    while ((received = recv(connection, chunk, sizeof(chunk), 0)) > 0) {
        response.append(chunk, received);
    }
    closesocket(connection);
    const size_t split = response.find("\r\n\r\n");
    int statusCode = 0;
    const size_t statusStart = response.find(' ');
    if (statusStart != std::string::npos) {
        try { statusCode = std::stoi(response.substr(statusStart + 1, 3)); }
        catch (...) { statusCode = 0; }
    }
    return finish(split == std::string::npos ? response : response.substr(split + 4), statusCode);
}

bool agentOk(const std::string& response) {
    try { return json::parse(response).at("ok").boolean(); }
    catch (...) { return false; }
}

std::optional<json::Value> agentJson(const char* method, const char* path, const std::string& body = {}) {
    try {
        const std::string response = agentRequest(method, path, body);
        if (response.empty()) return std::nullopt;
        return json::parse(response);
    } catch (...) {
        return std::nullopt;
    }
}

struct MonitorChoice {
    HMONITOR handle = nullptr;
    RECT work{};
    UINT dpi = 96;
    bool found = false;
    bool primary = true;
};

struct PlacementChoice {
    RECT work{};
    UINT dpi = 96;
};

BOOL CALLBACK collectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
    auto* choices = reinterpret_cast<std::vector<MonitorChoice>*>(data);
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(monitor, &info)) return TRUE;
    MonitorChoice choice{};
    choice.handle = monitor;
    choice.work = info.rcWork;
    choice.found = true;
    choice.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
    UINT dpiX = 96;
    UINT dpiY = 96;
    if (SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY))) {
        choice.dpi = dpiX;
    }
    choices->push_back(choice);
    return TRUE;
}

std::vector<MonitorChoice> desktopMonitors() {
    std::vector<MonitorChoice> choices;
    EnumDisplayMonitors(nullptr, nullptr, collectMonitor, reinterpret_cast<LPARAM>(&choices));
    std::stable_sort(choices.begin(), choices.end(), [](const auto& left, const auto& right) {
        return left.primary < right.primary;
    });
    return choices;
}

MonitorChoice chooseDesktopMonitor() {
    auto choices = desktopMonitors();
    if (!choices.empty()) return choices[std::clamp(g_ctrl.monitorIndex, 0, static_cast<int>(choices.size()) - 1)];
    MonitorChoice choice{};
    {
        choice.work = {80, 80, 1680, 980};
        choice.found = true;
    }
    return choice;
}

PlacementChoice chooseControllerPlacement() {
    POINT origin{0, 0};
    HMONITOR monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info{sizeof(info)};
    PlacementChoice choice{};
    if (monitor && GetMonitorInfoW(monitor, &info)) {
        choice.work = info.rcWork;
        UINT dpiX = 96;
        UINT dpiY = 96;
        if (SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY))) {
            choice.dpi = dpiX;
        } else {
            choice.dpi = GetDpiForSystem();
        }
        return choice;
    }
    choice.work = {80, 80, 1680, 980};
    choice.dpi = GetDpiForSystem();
    return choice;
}

int desktopDensity(int width, int height) {
    const int shortSide = std::min(width, height);
    return std::clamp(static_cast<int>(std::lround(shortSide * 160.0 / TARGET_SHORT_SIDE_DP)), 120, 480);
}

HWND findWindowForProcess(DWORD pid) {
    struct Search { DWORD pid; HWND window; } search{pid, nullptr};
    EnumWindows([](HWND window, LPARAM value) -> BOOL {
        auto* current = reinterpret_cast<Search*>(value);
        DWORD windowPid = 0;
        GetWindowThreadProcessId(window, &windowPid);
        if (windowPid == current->pid && IsWindowVisible(window) && !GetWindow(window, GW_OWNER)) {
            current->window = window;
            return FALSE;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&search));
    return search.window;
}

bool scrcpyIsForeground() {
    DWORD foregroundPid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &foregroundPid);
    if (foregroundPid == g_ctrl.scrcpyPid) return true;
    return std::any_of(g_ctrl.extraTransports.begin(), g_ctrl.extraTransports.end(), [foregroundPid](const auto& item) {
        return item.pid == foregroundPid;
    });
}

HWND foregroundScrcpyWindow() {
    const HWND foreground = GetForegroundWindow();
    DWORD pid = 0;
    GetWindowThreadProcessId(foreground, &pid);
    if (pid == g_ctrl.scrcpyPid) return g_ctrl.scrcpyWindow;
    for (const auto& item : g_ctrl.extraTransports) if (item.pid == pid) return item.window;
    return nullptr;
}

LRESULT CALLBACK keyboardHookProc(int code, WPARAM message, LPARAM data) {
    if (code == HC_ACTION && scrcpyIsForeground()) {
        const auto* event = reinterpret_cast<KBDLLHOOKSTRUCT*>(data);
        const bool altDown = (event->flags & LLKHF_ALTDOWN) != 0;
        const bool desktopChord = altDown && (event->vkCode == VK_TAB || event->vkCode == VK_F4);
        const HWND desktopWindow = foregroundScrcpyWindow();
        if (desktopChord && desktopWindow && IsWindow(desktopWindow)) {
            const bool keyUp = message == WM_KEYUP || message == WM_SYSKEYUP;
            const UINT forwarded = keyUp ? WM_SYSKEYUP : WM_SYSKEYDOWN;
            LPARAM flags = 1 | (1LL << 29);
            if (keyUp) flags |= (1LL << 30) | (1LL << 31);
            PostMessageW(desktopWindow, forwarded, event->vkCode, flags);
            return 1;
        }
        const bool windowsChord = (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 ||
                                  (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
        const bool ctrlAltChord = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 &&
                                  (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
        const bool shortcutDown = g_ctrl.shortcutPreset == 0 ? windowsChord
            : g_ctrl.shortcutPreset == 1 ? ctrlAltChord : false;
        if (shortcutDown && (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)) {
            int command = 0;
            if (event->vkCode == VK_LEFT) command = ID_SNAP_LEFT;
            if (event->vkCode == VK_RIGHT) command = ID_SNAP_RIGHT;
            if (event->vkCode == VK_UP) command = ID_MAXIMIZE_TASK;
            if (event->vkCode == VK_DOWN) command = ID_WINDOW_RESTORE;
            // Win+= / Win+- grow/shrink freeform window (OEM keys for + and -).
            if (event->vkCode == VK_OEM_PLUS || event->vkCode == VK_ADD) command = ID_WINDOW_LARGER;
            if (event->vkCode == VK_OEM_MINUS || event->vkCode == VK_SUBTRACT) command = ID_WINDOW_SMALLER;
            // Win+W / Win+Q: close the focused freeform app on the Pixel desktop.
            if (event->vkCode == 'W' || event->vkCode == 'Q') command = ID_CLOSE_FOCUSED_APP;
            if (command) {
                PostMessageW(g_ctrl.window, WM_COMMAND, command, 0);
                return 1;
            }
        }
        // Alt+F4 already closes freeform apps when forwarded above. Also accept
        // Ctrl+W while the desktop is focused (browser-like close).
        const bool ctrlOnly = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 &&
            (GetAsyncKeyState(VK_MENU) & 0x8000) == 0 &&
            (GetAsyncKeyState(VK_LWIN) & 0x8000) == 0 &&
            (GetAsyncKeyState(VK_RWIN) & 0x8000) == 0;
        if (ctrlOnly && event->vkCode == 'W' &&
            (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)) {
            PostMessageW(g_ctrl.window, WM_COMMAND, ID_CLOSE_FOCUSED_APP, 0);
            return 1;
        }
    }
    return CallNextHookEx(g_ctrl.keyboardHook, code, message, data);
}

void ensureKeyboardHook() {
    if (!g_ctrl.keyboardHook) {
        g_ctrl.keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHookProc, GetModuleHandleW(nullptr), 0);
    }
}

// Map a Windows screen point on a scrcpy HWND to Android display pixels.
bool mapScrcpyPointToAndroid(
    HWND root, POINT screenPt, int androidW, int androidH, int* outX, int* outY) {
    if (!root || !outX || !outY) return false;
    POINT client = screenPt;
    if (!ScreenToClient(root, &client)) return false;
    RECT cr{};
    if (!GetClientRect(root, &cr)) return false;
    const int cw = std::max(1L, cr.right - cr.left);
    const int ch = std::max(1L, cr.bottom - cr.top);
    const int aw = androidW > 0 ? androidW : cw;
    const int ah = androidH > 0 ? androidH : ch;
    *outX = static_cast<int>((static_cast<long long>(client.x) * aw) / cw);
    *outY = static_cast<int>((static_cast<long long>(client.y) * ah) / ch);
    *outX = std::clamp(*outX, 0, aw);
    *outY = std::clamp(*outY, 0, ah);
    return true;
}

// Tell the device agent about desktop pointer activity. The primary-button down
// marker must reach Android before scrcpy forwards the click, otherwise the
// launcher can create the app task on display 0 before the redirect is armed.
void notifyDesktopInputAsync(
    int displayId, int x = -1, int y = -1, const char* action = "down") {
    std::string body = std::string("{\"displayId\":") + std::to_string(displayId)
        + ",\"action\":\"" + action + "\"";
    if (x >= 0 && y >= 0) {
        body += ",\"x\":" + std::to_string(x) + ",\"y\":" + std::to_string(y);
    }
    body += "}";
    if (strcmp(action, "down") == 0) {
        // This is a short loopback request in the normal case (the agent keeps
        // its task snapshot warm). Keep a bounded timeout so a disconnected
        // agent cannot permanently capture the Windows mouse hook.
        agentRequest("POST", "/desktop/input", body, 500);
        return;
    }
    std::thread([body]() {
        agentRequest("POST", "/desktop/input", body, 250);
    }).detach();
}

// Low-level mouse hooks must stay bounded. Down markers are the one deliberate
// synchronous request; move/up notifications remain off the hook thread.
LRESULT CALLBACK mouseHookProc(int code, WPARAM message, LPARAM data) {
    if (code == HC_ACTION &&
        (message == WM_LBUTTONDOWN || message == WM_LBUTTONUP || message == WM_MOUSEMOVE)) {
        const auto* event = reinterpret_cast<MSLLHOOKSTRUCT*>(data);
        const HWND hit = WindowFromPoint(event->pt);
        const HWND root = hit ? GetAncestor(hit, GA_ROOT) : nullptr;
        DWORD rootPid = 0;
        if (root) GetWindowThreadProcessId(root, &rootPid);
        bool desktopWindow = g_ctrl.scrcpyPid != 0 && rootPid == g_ctrl.scrcpyPid;
        int displayId = desktopWindow ? g_ctrl.primaryDisplayId : 0;
        int androidW = desktopWindow ? g_ctrl.primaryDisplayWidth : 0;
        int androidH = desktopWindow ? g_ctrl.primaryDisplayHeight : 0;
        for (const auto& item : g_ctrl.extraTransports) {
            if (rootPid == item.pid) {
                desktopWindow = true;
                displayId = item.displayId;
                androidW = item.width;
                androidH = item.height;
            }
        }
        if (desktopWindow && root) {
            int ax = -1;
            int ay = -1;
            mapScrcpyPointToAndroid(root, event->pt, androidW, androidH, &ax, &ay);
            if (message == WM_LBUTTONDOWN) {
                notifyDesktopInputAsync(displayId, ax, ay, "down");
            } else if (message == WM_LBUTTONUP) {
                notifyDesktopInputAsync(displayId, ax, ay, "up");
            } else if (message == WM_MOUSEMOVE &&
                (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
                const ULONGLONG now = GetTickCount64();
                if (now - g_ctrl.lastDesktopMoveNotifyMs >= 40) {
                    g_ctrl.lastDesktopMoveNotifyMs = now;
                    notifyDesktopInputAsync(displayId, ax, ay, "move");
                }
            }
        }
    }
    return CallNextHookEx(g_ctrl.mouseHook, code, message, data);
}

void ensureMouseHook() {
    if (!g_ctrl.mouseHook) {
        g_ctrl.mouseHook = SetWindowsHookExW(WH_MOUSE_LL, mouseHookProc, GetModuleHandleW(nullptr), 0);
    }
}

void updateStatus(const std::wstring& status) {
    g_ctrl.status = status;
    if (g_ctrl.window) InvalidateRect(g_ctrl.window, nullptr, TRUE);
}

void refreshDevice();
void restartDesktop();

bool prepareDesktopLaunch() {
    refreshDevice();
    if (g_ctrl.serial.empty()) return false;
    for (int attempt = 0; attempt < 12; ++attempt) {
        auto response = agentJson("GET", "/status");
        if (response) return true;
        Sleep(250);
    }
    updateStatus(L"The Pixel agent is still starting. Try again in a moment.");
    return false;
}

void addTrayIcon() {
    if (g_ctrl.trayAdded) return;
    NOTIFYICONDATAW icon{sizeof(icon)};
    icon.hWnd = g_ctrl.window;
    icon.uID = 1;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    icon.uCallbackMessage = WM_TRAY;
    icon.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(icon.szTip, L"RewriteDEX Pixel Desktop");
    g_ctrl.trayAdded = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
}

void removeTrayIcon() {
    if (!g_ctrl.trayAdded) return;
    NOTIFYICONDATAW icon{sizeof(icon)};
    icon.hWnd = g_ctrl.window;
    icon.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &icon);
    g_ctrl.trayAdded = false;
}

void showControlWindow() {
    ShowWindow(g_ctrl.window, SW_RESTORE);
    // The host shell owns the visible command surface. Keep it above the
    // Android transport so its launcher/task controls never disappear behind
    // the Pixel desktop.
    SetWindowPos(g_ctrl.window, HWND_TOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW | SWP_NOACTIVATE);
    SetForegroundWindow(g_ctrl.window);
}

void toggleControlWindow() {
    if (IsWindowVisible(g_ctrl.window) && !IsIconic(g_ctrl.window)) {
        ShowWindow(g_ctrl.window, SW_HIDE);
    } else {
        showControlWindow();
    }
}

/** Bring the Pixel desktop scrcpy window to the front if it exists. */
void focusDesktopWindow() {
    if (!g_ctrl.scrcpyWindow || !IsWindow(g_ctrl.scrcpyWindow)) {
        if (g_ctrl.scrcpyPid != 0) {
            g_ctrl.scrcpyWindow = findWindowForProcess(g_ctrl.scrcpyPid);
        }
    }
    if (!g_ctrl.scrcpyWindow || !IsWindow(g_ctrl.scrcpyWindow)) return;
    if (IsIconic(g_ctrl.scrcpyWindow)) {
        ShowWindow(g_ctrl.scrcpyWindow, SW_RESTORE);
    } else {
        ShowWindow(g_ctrl.scrcpyWindow, SW_SHOW);
    }
    SetForegroundWindow(g_ctrl.scrcpyWindow);
    BringWindowToTop(g_ctrl.scrcpyWindow);
}

void refreshDevice();

void sendSystemAction(const char* action) {
    std::string response = agentRequest(
        "POST", "/system", std::string("{\"action\":\"") + action + "\"}");
    if (response.empty() && !g_ctrl.serial.empty()) {
        refreshDevice();
        response = agentRequest(
            "POST", "/system", std::string("{\"action\":\"") + action + "\"}");
    }
    if (!agentOk(response)) updateStatus(L"The Pixel agent did not accept that command.");
}

void syncTransportDisplays();

void launchPackage(const char* packageName) {
    syncTransportDisplays();
    const auto requestBody = [packageName]() {
        std::string body = std::string("{\"package\":\"") + packageName + "\"";
        // Bind controller/tray launches to the display selected from the live
        // transport map. Letting Android infer the display can fall back to
        // display 0 on Pixel builds even while the scrcpy desktop is healthy.
        if (g_ctrl.primaryDisplayId > 0) {
            body += ",\"displayId\":" + std::to_string(g_ctrl.primaryDisplayId);
        }
        body += "}";
        return body;
    };
    std::string response = agentRequest("POST", "/launch", requestBody());
    if (response.empty() && !g_ctrl.serial.empty()) {
        refreshDevice();
        syncTransportDisplays();
        response = agentRequest("POST", "/launch", requestBody());
    }
    updateStatus(agentOk(response) ? L"Opened the app on the Pixel desktop."
                                   : L"The Pixel agent could not launch the app.");
}

void refreshDevice() {
    const std::wstring devices = runAdb(L"devices");
    g_ctrl.serial.clear();
    std::wistringstream lines(devices);
    std::wstring line;
    while (std::getline(lines, line)) {
        const size_t separator = line.find(L'\t');
        if (separator == std::wstring::npos || line.find(L"\tdevice") == std::wstring::npos) continue;
        const std::wstring serial = line.substr(0, separator);
        if (serial.rfind(L"emulator-", 0) != 0) {
            g_ctrl.serial = serial;
            break;
        }
    }

    if (g_ctrl.serial.empty()) {
        updateStatus(L"No authorized Pixel found. Connect it over USB and approve debugging.");
        return;
    }

    // External/virtual displays only — do not force phone UI into freeform.
    runAdb(L"-s " + g_ctrl.serial + L" shell settings put secure show_ime_with_hard_keyboard 0");
    runAdb(L"-s " + g_ctrl.serial + L" shell settings put global enable_freeform_support 1");
    runAdb(L"-s " + g_ctrl.serial + L" shell settings put global force_desktop_mode_on_external_displays 1");
    runAdb(L"-s " + g_ctrl.serial + L" forward tcp:8792 tcp:8792");
    runAdb(L"-s " + g_ctrl.serial +
        L" shell am start-foreground-service -n com.rewritedex.nativeagent/.DexAgentService"
        L" --es token " + std::wstring(g_ctrl.sessionToken.begin(), g_ctrl.sessionToken.end()));
    const std::string response = agentRequest("GET", "/status");
    updateStatus(agentOk(response)
        ? L"Pixel connected. Android owns the desktop shell; RewriteDEX is ready to transport it."
        : L"Pixel connected, but the RewriteDEX agent is not responding.");
}

int preferredPhysicalDisplayId() {
    if (!g_ctrl.preferPhysicalDisplay) return 0;
    auto status = agentJson("GET", "/status");
    if (!status || !status->at("displays").is_array()) return 0;
    for (const auto& display : status->at("displays").array()) {
        if (display.at("physical").boolean() && display.at("state").integer() == 2) {
            return display.at("id").integer();
        }
    }
    return 0;
}

std::wstring qualityArguments() {
    if (g_ctrl.qualityProfile == 0) {
        return L" --video-codec=h264 --video-bit-rate=6M --max-fps=45 --audio-buffer=20 --audio-output-buffer=10";
    }
    if (g_ctrl.qualityProfile == 2) {
        return L" --video-codec=h264 --video-bit-rate=16M --max-fps=60 --audio-buffer=40 --audio-output-buffer=20";
    }
    // Default: conservative encode for long-lived virtual-display sessions.
    return L" --video-codec=h264 --video-bit-rate=8M --max-fps=30 --audio-buffer=30 --audio-output-buffer=10";
}

std::filesystem::path recordingPath() {
    const auto directory = knownFolder(FOLDERID_Videos, L".") / L"RewriteDEX";
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    SYSTEMTIME time{};
    GetLocalTime(&time);
    wchar_t name[80]{};
    swprintf_s(name, L"RewriteDEX-%04d%02d%02d-%02d%02d%02d.mkv",
        time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
    return directory / name;
}

bool startExtraTransport(const MonitorChoice& monitor, int ordinal) {
    const auto scrcpy = scrcpyForkPath();
    const int workWidth = monitor.work.right - monitor.work.left;
    const int workHeight = monitor.work.bottom - monitor.work.top;
    const int margin = scaleForDpi(20, monitor.dpi);
    int width = std::max(960, workWidth - margin * 2) & ~1;
    int height = std::max(600, workHeight - margin * 2) & ~1;
    const int x = monitor.work.left + (workWidth - width) / 2;
    const int y = monitor.work.top + (workHeight - height) / 2;
    std::wstring command = quote(scrcpy.wstring()) + L" -s " + g_ctrl.serial
        + L" --new-display=" + std::to_wstring(width) + L"x" + std::to_wstring(height)
        + L"/" + std::to_wstring(desktopDensity(width, height))
        + L" --desktop-transport"
        + L" --window-title=RewriteDEX_Pixel_Desktop_" + std::to_wstring(ordinal)
        + L" --window-x=" + std::to_wstring(x) + L" --window-y=" + std::to_wstring(y)
        + L" --no-window-aspect-ratio-lock --display-ime-policy=hide"
        // Consistent input backend with primary desktop (see launchPixelDesktop comments)
        + L" --keyboard=uhid --mouse=sdk --gamepad=uhid --shortcut-mod=lsuper"
        + L" --push-target=/sdcard/Download/ --keep-active --disable-screensaver"
        + (g_ctrl.audioEnabled ? L"" : L" --no-audio")
        + qualityArguments();
    std::vector<wchar_t> buffer(command.begin(), command.end());
    buffer.push_back(L'\0');
    const auto server = scrcpy.parent_path() / L"scrcpy-server";
    SetEnvironmentVariableW(L"SCRCPY_SERVER_PATH", server.c_str());
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    // scrcpy-fork is a console PE; CREATE_NO_WINDOW avoids a permanent black
    // terminal next to the desktop window.
    const BOOL started = CreateProcessW(
        nullptr, buffer.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
        nullptr, scrcpy.parent_path().c_str(), &startup, &process);
    SetEnvironmentVariableW(L"SCRCPY_SERVER_PATH", nullptr);
    if (!started) return false;
    CloseHandle(process.hThread);
    if (g_ctrl.scrcpyJob) AssignProcessToJobObject(g_ctrl.scrcpyJob, process.hProcess);
    g_ctrl.extraTransports.push_back({process.hProcess, process.dwProcessId, nullptr, 0, 0, 0});
    return true;
}

void closeTaskSurfaces() {
    for (auto& item : g_ctrl.taskSurfaces) {
        if (!item.process) continue;
        if (WaitForSingleObject(item.process, 0) == WAIT_TIMEOUT) {
            if ((!item.window || !IsWindow(item.window)) && item.pid) {
                item.window = findWindowForProcess(item.pid);
            }
            if (item.window && IsWindow(item.window)) {
                PostMessageW(item.window, WM_CLOSE, 0, 0);
            }
            if (WaitForSingleObject(item.process, 1500) == WAIT_TIMEOUT) {
                TerminateProcess(item.process, 0);
                WaitForSingleObject(item.process, 500);
            }
        }
        CloseHandle(item.process);
    }
    g_ctrl.taskSurfaces.clear();
}

bool focusTaskSurface(int taskId) {
    for (auto& item : g_ctrl.taskSurfaces) {
        if (item.taskId != taskId || !item.process ||
            WaitForSingleObject(item.process, 0) != WAIT_TIMEOUT) {
            continue;
        }
        if (!item.window || !IsWindow(item.window)) {
            item.window = findWindowForProcess(item.pid);
        }
        if (!item.window || !IsWindow(item.window)) return false;
        ShowWindow(item.window, IsIconic(item.window) ? SW_RESTORE : SW_SHOW);
        BringWindowToTop(item.window);
        SetForegroundWindow(item.window);
        return true;
    }
    return false;
}

bool closeTaskSurface(int taskId) {
    for (auto iterator = g_ctrl.taskSurfaces.begin();
            iterator != g_ctrl.taskSurfaces.end(); ++iterator) {
        if (iterator->taskId != taskId) continue;
        if (iterator->process &&
            WaitForSingleObject(iterator->process, 0) == WAIT_TIMEOUT) {
            if (!iterator->window || !IsWindow(iterator->window)) {
                iterator->window = findWindowForProcess(iterator->pid);
            }
            if (iterator->window && IsWindow(iterator->window)) {
                PostMessageW(iterator->window, WM_CLOSE, 0, 0);
            }
            if (WaitForSingleObject(iterator->process, 1500) == WAIT_TIMEOUT) {
                TerminateProcess(iterator->process, 0);
                WaitForSingleObject(iterator->process, 500);
            }
        }
        if (iterator->process) CloseHandle(iterator->process);
        g_ctrl.taskSurfaces.erase(iterator);
        return true;
    }
    return false;
}

bool hasTaskSurface(int taskId) {
    return std::any_of(
        g_ctrl.taskSurfaces.begin(),
        g_ctrl.taskSurfaces.end(),
        [taskId](const auto& item) {
            return item.taskId == taskId && item.process &&
                WaitForSingleObject(item.process, 0) == WAIT_TIMEOUT;
        });
}

void stopTaskBroker() {
    if (g_ctrl.serial.empty()) return;
    const auto server = scrcpyForkPath().parent_path() / L"scrcpy-server";
    if (std::filesystem::exists(server)) {
        runAdb(
            L"-s " + g_ctrl.serial + L" push " + quote(server.wstring()) +
            L" /data/local/tmp/scrcpy-server.jar",
            5000);
    }
    runAdb(
        L"-s " + g_ctrl.serial +
        L" shell CLASSPATH=/data/local/tmp/scrcpy-server.jar"
        L" app_process /"
        L" com.genymobile.scrcpy.compositor.CompositorBrokerControl stop",
        2500);
}

bool taskBrokerReady() {
    if (g_ctrl.serial.empty()) return false;
    const std::wstring response = runAdb(
        L"-s " + g_ctrl.serial +
        L" shell CLASSPATH=/data/local/tmp/scrcpy-server.jar"
        L" app_process /"
        L" com.genymobile.scrcpy.compositor.CompositorBrokerControl ping",
        2500);
    return response.find(L"RWD_BROKER ready=true") != std::wstring::npos;
}

bool ensureTaskBroker(const std::filesystem::path& server) {
    if (g_ctrl.serial.empty() || !std::filesystem::exists(server)) return false;

    runAdb(
        L"-s " + g_ctrl.serial + L" push " + quote(server.wstring()) +
        L" /data/local/tmp/scrcpy-server.jar",
        5000);
    if (taskBrokerReady()) return true;

    const std::wstring brokerCommand =
        L"CLASSPATH=/data/local/tmp/scrcpy-server.jar"
        L" app_process /"
        L" com.genymobile.scrcpy.compositor.CompositorBroker"
        L" >/data/local/tmp/rewritedex-compositor.log 2>&1 &";
    runAdb(
        L"-s " + g_ctrl.serial + L" shell su -c " + quote(brokerCommand),
        2500);

    for (int attempt = 0; attempt < 16; ++attempt) {
        Sleep(250);
        if (taskBrokerReady()) return true;
    }
    return false;
}

bool startTaskSurface(int taskId, int displayId, const std::string& packageName) {
    if (taskId < 0 || g_ctrl.serial.empty()) return false;

    if (hasTaskSurface(taskId)) {
        return focusTaskSurface(taskId);
    }

    if (!packageName.empty()) {
        const std::string focusBody = "{\"action\":\"focus\",\"taskId\":"
            + std::to_string(taskId)
            + ",\"displayId\":" + std::to_string(displayId)
            + ",\"package\":" + json::quote(packageName) + "}";
        if (!agentOk(agentRequest("POST", "/task", focusBody))) {
            updateStatus(L"The Android task could not be focused for capture.");
            return false;
        }
        Sleep(150);
    }

    const auto scrcpy = scrcpyForkPath();
    const auto server = scrcpy.parent_path() / L"scrcpy-server";
    if (!std::filesystem::exists(scrcpy) || !std::filesystem::exists(server)) {
        updateStatus(L"The task compositor runtime is incomplete.");
        return false;
    }
    if (!ensureTaskBroker(server)) {
        updateStatus(
            L"The rooted task compositor broker could not be started.");
        return false;
    }

    std::wstring command = quote(scrcpy.wstring()) + L" -s " + g_ctrl.serial
        + L" --task-id=" + std::to_wstring(taskId)
        + L" --display-id=" + std::to_wstring(displayId)
        + L" --window-title=RewriteDEX_Task_" + std::to_wstring(taskId)
        + L" --window-x=" + std::to_wstring(120 + 36 * g_ctrl.taskSurfaces.size())
        + L" --window-y=" + std::to_wstring(120 + 36 * g_ctrl.taskSurfaces.size())
        + L" --keyboard=sdk --mouse=sdk --shortcut-mod=lsuper"
        + L" --no-audio --no-clipboard-autosync --no-cleanup --keep-active"
        + L" --video-codec=h264"
        + qualityArguments();
    std::vector<wchar_t> buffer(command.begin(), command.end());
    buffer.push_back(L'\0');

    const DWORD existingLength = GetEnvironmentVariableW(L"SCRCPY_SERVER_PATH", nullptr, 0);
    std::wstring existingServer;
    if (existingLength > 0) {
        existingServer.resize(existingLength);
        GetEnvironmentVariableW(
            L"SCRCPY_SERVER_PATH", existingServer.data(), existingLength);
        existingServer.resize(wcslen(existingServer.c_str()));
    }
    SetEnvironmentVariableW(L"SCRCPY_SERVER_PATH", server.c_str());

    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    const BOOL started = CreateProcessW(
        nullptr,
        buffer.data(),
        nullptr,
        nullptr,
        FALSE,
        CREATE_NO_WINDOW,
        nullptr,
        scrcpy.parent_path().c_str(),
        &startup,
        &process);
    SetEnvironmentVariableW(
        L"SCRCPY_SERVER_PATH", existingLength > 0 ? existingServer.c_str() : nullptr);
    if (!started) {
        updateStatus(L"Could not start the task compositor window.");
        return false;
    }

    CloseHandle(process.hThread);
    if (g_ctrl.scrcpyJob) AssignProcessToJobObject(g_ctrl.scrcpyJob, process.hProcess);
    g_ctrl.taskSurfaces.push_back({
        process.hProcess,
        process.dwProcessId,
        nullptr,
        taskId,
        displayId,
    });
    SetTimer(g_ctrl.window, PROCESS_TIMER, 200, nullptr);
    updateStatus(
        L"Opening native Android task surface " + std::to_wstring(taskId) + L"...");
    return true;
}

void syncTransportDisplays() {
    auto status = agentJson("GET", "/status");
    if (!status || !status->at("displays").is_array()) return;
    std::vector<int> virtualDisplays;
    std::unordered_map<int, std::pair<int, int>> sizes;
    int physical = 0;
    for (const auto& display : status->at("displays").array()) {
        const int id = display.at("id").integer();
        std::string name;
        try {
            name = display.at("name").string();
        } catch (...) {
        }
        if (name.rfind("RewriteDEX-broker-task-", 0) == 0) {
            continue;
        }
        int w = 0;
        int h = 0;
        try {
            w = display.at("width").integer();
            h = display.at("height").integer();
        } catch (...) {
        }
        if (w > 0 && h > 0) sizes[id] = {w, h};
        if (id == 0 || display.at("state").integer() != 2) continue;
        if (display.at("physical").boolean()) physical = id;
        else virtualDisplays.push_back(id);
    }
    std::sort(virtualDisplays.begin(), virtualDisplays.end());
    std::vector<int> newVirtualDisplays;
    for (const int id : virtualDisplays) {
        if (std::find(
                g_ctrl.launchBaselineVirtualDisplays.begin(),
                g_ctrl.launchBaselineVirtualDisplays.end(), id) ==
            g_ctrl.launchBaselineVirtualDisplays.end()) {
            newVirtualDisplays.push_back(id);
        }
    }

    if (preferredPhysicalDisplayId() > 0 && physical > 0) {
        g_ctrl.primaryDisplayId = physical;
    } else if (!newVirtualDisplays.empty()) {
        // The primary scrcpy process is created before extra transports, so
        // the first newly-created ID belongs to the visible primary window.
        g_ctrl.primaryDisplayId = newVirtualDisplays.front();
    } else if (std::find(virtualDisplays.begin(), virtualDisplays.end(), g_ctrl.primaryDisplayId) ==
               virtualDisplays.end() && !virtualDisplays.empty()) {
        // Safe fallback for sessions started before baseline tracking existed.
        g_ctrl.primaryDisplayId = virtualDisplays.back();
    }
    if (const auto found = sizes.find(g_ctrl.primaryDisplayId); found != sizes.end()) {
        g_ctrl.primaryDisplayWidth = found->second.first;
        g_ctrl.primaryDisplayHeight = found->second.second;
    }
    for (size_t i = 0; i < g_ctrl.extraTransports.size(); ++i) {
        if (i + 1 < newVirtualDisplays.size()) {
            g_ctrl.extraTransports[i].displayId = newVirtualDisplays[i + 1];
            if (const auto found = sizes.find(g_ctrl.extraTransports[i].displayId); found != sizes.end()) {
                g_ctrl.extraTransports[i].width = found->second.first;
                g_ctrl.extraTransports[i].height = found->second.second;
            }
        }
    }
}

void launchPixelDesktop() {
    if (g_ctrl.scrcpyProcess && WaitForSingleObject(g_ctrl.scrcpyProcess, 0) == WAIT_TIMEOUT) {
        focusDesktopWindow();
        updateStatus(L"The Pixel desktop is already running.");
        return;
    }
    if (!prepareDesktopLaunch()) {
        if (g_ctrl.serial.empty()) {
            updateStatus(L"Connect and authorize the Pixel first.");
        }
        return;
    }

    // Snapshot the live virtual-display set before creating this session. The
    // Android display IDs are global and can outlive a scrcpy window, so the
    // lowest ID is not necessarily the display represented by this process.
    g_ctrl.launchBaselineVirtualDisplays.clear();
    if (const auto status = agentJson("GET", "/status")) {
        if (status->at("displays").is_array()) {
            for (const auto& display : status->at("displays").array()) {
                if (display.at("id").integer() > 0 &&
                    !display.at("physical").boolean() &&
                    display.at("state").integer() == 2) {
                    g_ctrl.launchBaselineVirtualDisplays.push_back(display.at("id").integer());
                }
            }
        }
    }

    const std::filesystem::path scrcpy = scrcpyForkPath();
    if (!std::filesystem::exists(scrcpy)) {
        updateStatus(L"scrcpy-fork.exe was not found in the RewriteDEX runtime.");
        return;
    }
    // Surface the exact fork binary so a stock scrcpy shadow is easy to spot.
    updateStatus(L"Starting desktop via " + scrcpy.wstring());

    const MonitorChoice monitor = chooseDesktopMonitor();
    const int workWidth = monitor.work.right - monitor.work.left;
    const int workHeight = monitor.work.bottom - monitor.work.top;
    const int margin = scaleForDpi(20, monitor.dpi);
    // Cap virtual-display size: full-monitor 2.5K streams are unstable on Pixel
    // encoders and tend to drop the desktop mid-session.
    constexpr int kMaxDesktopWidth = 1600;
    constexpr int kMaxDesktopHeight = 900;
    int width = std::max(960, workWidth - margin * 2);
    int height = std::max(600, workHeight - margin * 2);
    width = std::min(width, kMaxDesktopWidth);
    height = std::min(height, kMaxDesktopHeight);
    width &= ~1;
    height &= ~1;
    const int x = monitor.work.left + (workWidth - width) / 2;
    const int y = monitor.work.top + (workHeight - height) / 2;
    const int density = desktopDensity(width, height);

    const int physicalDisplayId = preferredPhysicalDisplayId();
    std::wstring command = quote(scrcpy.wstring()) + L" -s " + g_ctrl.serial;
    if (physicalDisplayId > 0) {
        command += L" --display-id=" + std::to_wstring(physicalDisplayId)
            + L" --window-width=" + std::to_wstring(width)
            + L" --window-height=" + std::to_wstring(height);
    } else {
        command += L" --new-display=" + std::to_wstring(width) + L"x" + std::to_wstring(height)
            + L"/" + std::to_wstring(density)
            + L" --desktop-transport"
            // DeX isolation: do NOT pass --no-vd-destroy-content (that dumps apps
            // onto the phone when the stream dies). The fork's desktop transport
            // keeps the initial virtual-display dimensions and density stable.
            ;
    }
    command += L" --window-title=RewriteDEX_Pixel_Desktop";
    command += L" --window-x=" + std::to_wstring(x)
        + L" --window-y=" + std::to_wstring(y)
        + L" --no-window-aspect-ratio-lock"
        + L" --display-ime-policy=hide"
        // UHID keyboard + absolute SDK mouse chosen for desktop:
        // - uhid keyboard for reliable Alt+Tab etc. and shortcuts on virtual desktop
        // - sdk mouse (absolute) for free cursor leave + caption interaction on freeform
        // gamepad=uhid for completeness. Matches extra transport and fork guidance.
        + L" --keyboard=uhid --mouse=sdk --gamepad=uhid --shortcut-mod=lsuper"
        + L" --push-target=/sdcard/Download/"
        + L" --keep-active"
        + L" --disable-screensaver"
        + (g_ctrl.audioEnabled ? L"" : L" --no-audio")
        + qualityArguments();
    if (g_ctrl.recording) command += L" --record=" + quote(recordingPath().wstring());

    std::vector<wchar_t> buffer(command.begin(), command.end());
    buffer.push_back(L'\0');
    const std::filesystem::path server = scrcpy.parent_path() / L"scrcpy-server";
    if (!std::filesystem::exists(server)) {
        updateStatus(L"scrcpy-server was not found beside scrcpy-fork.exe.");
        return;
    }
    const DWORD existingLength = GetEnvironmentVariableW(L"SCRCPY_SERVER_PATH", nullptr, 0);
    std::wstring existingServer;
    if (existingLength > 0) {
        existingServer.resize(existingLength);
        GetEnvironmentVariableW(
            L"SCRCPY_SERVER_PATH", existingServer.data(), existingLength);
        existingServer.resize(wcslen(existingServer.c_str()));
    }
    SetEnvironmentVariableW(L"SCRCPY_SERVER_PATH", server.c_str());

    // Append scrcpy stdout/stderr so sudden drops are diagnosable without a console.
    const std::filesystem::path logPath = moduleDirectory() / L"scrcpy-session.log";
    SECURITY_ATTRIBUTES inherit{sizeof(inherit), nullptr, TRUE};
    HANDLE logFile = CreateFileW(
        logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    BOOL started = FALSE;
    // Console PE without a visible terminal. Do not use CREATE_BREAKAWAY_FROM_JOB:
    // it fails CreateProcess when the parent job disallows breakaway (common under
    // shell hosts), which left the user with no desktop window at all.
    const DWORD createFlags = CREATE_NO_WINDOW;
    if (logFile != INVALID_HANDLE_VALUE) {
        SetFilePointer(logFile, 0, nullptr, FILE_END);
        const char header[] = "\n----- RewriteDEX scrcpy session -----\n";
        DWORD written = 0;
        WriteFile(logFile, header, static_cast<DWORD>(sizeof(header) - 1), &written, nullptr);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = INVALID_HANDLE_VALUE;
        startup.hStdOutput = logFile;
        startup.hStdError = logFile;
        // scrcpy-fork is a console PE; CREATE_NO_WINDOW avoids a permanent black
        // terminal next to the desktop window. Inherit log handles for capture.
        started = CreateProcessW(
            nullptr, buffer.data(), nullptr, nullptr, TRUE, createFlags, nullptr,
            scrcpy.parent_path().c_str(), &startup, &process);
        CloseHandle(logFile);
    } else {
        started = CreateProcessW(
            nullptr, buffer.data(), nullptr, nullptr, FALSE, createFlags, nullptr,
            scrcpy.parent_path().c_str(), &startup, &process);
    }
    SetEnvironmentVariableW(
        L"SCRCPY_SERVER_PATH", existingLength > 0 ? existingServer.c_str() : nullptr);
    if (!started) {
        updateStatus(L"Could not start scrcpy-fork.exe.");
        return;
    }

    CloseHandle(process.hThread);
    if (g_ctrl.scrcpyProcess) CloseHandle(g_ctrl.scrcpyProcess);
    g_ctrl.scrcpyProcess = process.hProcess;
    g_ctrl.scrcpyPid = process.dwProcessId;
    // Do not assign scrcpy to a kill-on-close job — the desktop window must stay
    // independent of the controller process lifetime (DeX-style).
    g_ctrl.extraTransports.clear();
    if (g_ctrl.allMonitors) {
        const auto monitors = desktopMonitors();
        const int selected = std::clamp(g_ctrl.monitorIndex, 0, std::max(0, static_cast<int>(monitors.size()) - 1));
        for (int i = 0; i < static_cast<int>(monitors.size()); ++i) {
            if (i != selected) startExtraTransport(monitors[i], i + 1);
        }
    }
    g_ctrl.scrcpyWindow = nullptr;
    g_ctrl.primaryDisplayId = physicalDisplayId;
    ensureKeyboardHook();
    ensureMouseHook();
    SetTimer(g_ctrl.window, PROCESS_TIMER, 200, nullptr);
    SetTimer(g_ctrl.window, SESSION_TIMER, 30000, nullptr);
    SetTimer(g_ctrl.window, EXPORT_TIMER, 5000, nullptr);
    addTrayIcon();
    // Keep the control panel visible so the user has an always-available
    // toolbar while the desktop is running.
    showControlWindow();
    updateStatus(L"Pixel desktop transport started.");
    g_ctrl.desktopRequested = true;
}

void stopDesktopTracking() {
    KillTimer(g_ctrl.window, PROCESS_TIMER);
    KillTimer(g_ctrl.window, SESSION_TIMER);
    KillTimer(g_ctrl.window, EXPORT_TIMER);
    if (g_ctrl.scrcpyProcess) {
        CloseHandle(g_ctrl.scrcpyProcess);
        g_ctrl.scrcpyProcess = nullptr;
    }
    g_ctrl.scrcpyPid = 0;
    g_ctrl.scrcpyWindow = nullptr;
    g_ctrl.primaryDisplayId = 0;
    for (auto& item : g_ctrl.extraTransports) {
        if (item.process && WaitForSingleObject(item.process, 0) == WAIT_TIMEOUT) {
            if (item.window && IsWindow(item.window)) PostMessageW(item.window, WM_CLOSE, 0, 0);
            if (WaitForSingleObject(item.process, 800) == WAIT_TIMEOUT) TerminateProcess(item.process, 0);
        }
        if (item.process) CloseHandle(item.process);
    }
    g_ctrl.extraTransports.clear();
}

void closePixelDesktop() {
    if (!g_ctrl.scrcpyProcess || WaitForSingleObject(g_ctrl.scrcpyProcess, 0) != WAIT_TIMEOUT) {
        stopDesktopTracking();
        return;
    }
    if (g_ctrl.scrcpyWindow && IsWindow(g_ctrl.scrcpyWindow)) {
        PostMessageW(g_ctrl.scrcpyWindow, WM_CLOSE, 0, 0);
    }
    if (WaitForSingleObject(g_ctrl.scrcpyProcess, 2500) == WAIT_TIMEOUT) {
        TerminateProcess(g_ctrl.scrcpyProcess, 0);
        WaitForSingleObject(g_ctrl.scrcpyProcess, 1000);
    }
    for (auto& item : g_ctrl.extraTransports) {
        if (!item.process || WaitForSingleObject(item.process, 0) != WAIT_TIMEOUT) continue;
        if (item.window && IsWindow(item.window)) PostMessageW(item.window, WM_CLOSE, 0, 0);
        if (WaitForSingleObject(item.process, 1200) == WAIT_TIMEOUT) TerminateProcess(item.process, 0);
    }
    stopDesktopTracking();
}

int addDynamic(HMENU menu, const std::wstring& label, RewriteDEXController::DynamicAction action, UINT flags = MF_STRING) {
    static int nextId = DYNAMIC_ID_FIRST;
    if (nextId > 30000) nextId = DYNAMIC_ID_FIRST;
    while (g_ctrl.dynamicActions.contains(nextId)) ++nextId;
    const int id = nextId++;
    g_ctrl.dynamicActions[id] = std::move(action);
    AppendMenuW(menu, flags, id, label.c_str());
    return id;
}

struct HostAppEntry {
    std::string packageName;
    std::wstring label;
};

std::vector<HostAppEntry> hostAppInventory() {
    std::vector<HostAppEntry> apps;
    const auto response = agentJson("GET", "/api/v1/apps");
    if (!response || !response->at("apps").is_array()) return apps;
    for (const auto& item : response->at("apps").array()) {
        const std::string packageName = item.at("package").string();
        if (packageName.empty()) continue;
        std::wstring label = utf8ToWide(item.at("label").string(packageName));
        if (label.empty()) label = utf8ToWide(packageName);
        apps.push_back({packageName, std::move(label)});
    }
    return apps;
}

void appendWindowsLauncherMenu(HMENU parent) {
    const auto apps = hostAppInventory();
    if (apps.empty()) {
        AppendMenuW(parent, MF_STRING | MF_GRAYED, 0,
            L"Connect the Pixel to load Android apps");
        return;
    }
    std::unordered_map<std::string, std::wstring> labels;
    for (const auto& app : apps) labels.emplace(app.packageName, app.label);
    const auto addApp = [&](HMENU menu, const std::string& packageName, const std::wstring& label) {
        const std::string launchBody = "{\"package\":" + json::quote(packageName) + "}";
        addDynamic(menu, label, {"POST", "/launch", launchBody, L"Opened Android app in the Windows workspace.", packageName});
    };

    if (g_ctrl.hostWorkspace) {
        HMENU pinned = CreatePopupMenu();
        int pinnedCount = 0;
        for (const auto& packageName : g_ctrl.hostWorkspace->pinnedApps()) {
            const auto found = labels.find(packageName);
            if (found == labels.end()) continue;
            addApp(pinned, packageName, found->second);
            ++pinnedCount;
        }
        if (pinnedCount) AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(pinned), L"Pinned on Windows");
        else DestroyMenu(pinned);

        HMENU recent = CreatePopupMenu();
        int recentCount = 0;
        for (const auto& packageName : g_ctrl.hostWorkspace->recentApps()) {
            const auto found = labels.find(packageName);
            if (found == labels.end()) continue;
            addApp(recent, packageName, found->second);
            ++recentCount;
        }
        if (recentCount) AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(recent), L"Recent on Windows");
        else DestroyMenu(recent);
    }

    HMENU allApps = CreatePopupMenu();
    for (const auto& app : apps) {
        HMENU appMenu = CreatePopupMenu();
        addApp(appMenu, app.packageName, app.label);
        const bool pinned = g_ctrl.hostWorkspace && g_ctrl.hostWorkspace->isPinned(app.packageName);
        addDynamic(appMenu, pinned ? L"Unpin from Windows" : L"Pin to Windows", {
            "LOCAL", "pin:" + app.packageName, "", pinned ? L"Removed Windows pin." : L"Pinned for this Windows desktop.",
        });
        AppendMenuW(allApps, MF_POPUP, reinterpret_cast<UINT_PTR>(appMenu), app.label.c_str());
    }
    AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(allApps), L"All Android apps");
}

void appendHostWorkspacesMenu(HMENU parent) {
    std::vector<std::string> names{"Desktop", "Work", "Media", "Personal"};
    const auto response = agentJson("GET", "/workspaces");
    if (response && response->at("workspaces").is_array()) {
        for (const auto& item : response->at("workspaces").array()) {
            const std::string name = item.at("name").string();
            if (!name.empty() && std::find(names.begin(), names.end(), name) == names.end()) names.push_back(name);
        }
    }
    for (const auto& name : names) {
        const std::string body = "{\"name\":" + json::quote(name) + "}";
        const std::wstring label = utf8ToWide(name);
        if (name == "Desktop") {
            addDynamic(parent, label, {"LOCAL", "workspace:" + name, "", L"Selected Windows desktop workspace.", "", name});
        } else {
            addDynamic(parent, label, {"POST", "/workspace/restore", body, L"Restored workspace into the Windows desktop.", "", name});
        }
    }
}

void showWindowsLauncher() {
    HMENU menu = CreatePopupMenu();
    appendWindowsLauncherMenu(menu);
    RECT bounds{};
    const HWND button = GetDlgItem(g_ctrl.window, ID_HOST_LAUNCHER);
    GetWindowRect(button ? button : g_ctrl.window, &bounds);
    SetForegroundWindow(g_ctrl.window);
    TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN, bounds.left, bounds.top, 0, g_ctrl.window, nullptr);
    DestroyMenu(menu);
}

void showHostWorkspaces() {
    HMENU menu = CreatePopupMenu();
    appendHostWorkspacesMenu(menu);
    RECT bounds{};
    const HWND button = GetDlgItem(g_ctrl.window, ID_HOST_WORKSPACES);
    GetWindowRect(button ? button : g_ctrl.window, &bounds);
    SetForegroundWindow(g_ctrl.window);
    TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN, bounds.left, bounds.top, 0, g_ctrl.window, nullptr);
    DestroyMenu(menu);
}

std::string taskBody(const json::Value& task, const char* action) {
    return "{\"action\":" + json::quote(action)
        + ",\"taskId\":" + std::to_string(task.at("taskId").integer())
        + ",\"displayId\":" + std::to_string(task.at("displayId").integer())
        + ",\"package\":" + json::quote(task.at("package").string()) + "}";
}

void appendTasksMenu(HMENU parent) {
    HMENU tasksMenu = CreatePopupMenu();
    auto response = agentJson("GET", "/tasks");
    int count = 0;
    if (response && response->at("tasks").is_array()) {
        for (const auto& task : response->at("tasks").array()) {
            if (task.at("displayId").integer() == 0 || task.at("package").string().empty()) continue;
            HMENU app = CreatePopupMenu();
            const std::string packageName = task.at("package").string();
            const int taskId = task.at("taskId").integer();
            const int displayId = task.at("displayId").integer();
            if (hasTaskSurface(taskId)) {
                addDynamic(app, L"Focus native surface", {
                    "LOCAL",
                    "task-surface-focus:" + std::to_string(taskId),
                    "",
                    L"Focused the native Android task surface.",
                    packageName,
                });
                addDynamic(app, L"Close native surface", {
                    "LOCAL",
                    "task-surface-close:" + std::to_string(taskId),
                    "",
                    L"Closed the native Android task surface.",
                    packageName,
                });
            } else {
                addDynamic(app, L"Open native surface (broker)", {
                    "LOCAL",
                    "task-surface:" + std::to_string(taskId) + ":" + std::to_string(displayId),
                    "",
                    L"Opened the Android task as an independent Windows surface.",
                    packageName,
                });
            }
            AppendMenuW(app, MF_SEPARATOR, 0, nullptr);
            addDynamic(app, L"Focus", {"POST", "/task", taskBody(task, "focus"), L"Focused the desktop app."});
            addDynamic(app, L"New window", {"POST", "/task", taskBody(task, "new-window"), L"Opened a new app window."});
            addDynamic(app, L"Move to phone", {"POST", "/task", taskBody(task, "move-phone"), L"Moved the app to the phone."});
            HMENU sizes = CreatePopupMenu();
            // Immediate resize presets (not only future-launch profiles).
            const std::string resizeBase = "{\"action\":\"preset\",\"taskId\":"
                + std::to_string(taskId) + ",\"displayId\":" + std::to_string(displayId)
                + ",\"package\":" + json::quote(packageName) + ",\"preset\":";
            addDynamic(sizes, L"Snap left", {"POST", "/task", resizeBase + "\"left\"}", L"Snapped the window left."});
            addDynamic(sizes, L"Snap right", {"POST", "/task", resizeBase + "\"right\"}", L"Snapped the window right."});
            addDynamic(sizes, L"Maximize", {"POST", "/task", resizeBase + "\"maximize\"}", L"Maximized the window."});
            addDynamic(sizes, L"Floating center", {"POST", "/task", resizeBase + "\"restore\"}", L"Restored floating size."});
            addDynamic(sizes, L"Phone size", {"POST", "/task", resizeBase + "\"phone\"}", L"Phone-sized the window."});
            addDynamic(sizes, L"Tablet size", {"POST", "/task", resizeBase + "\"tablet\"}", L"Tablet-sized the window."});
            AppendMenuW(sizes, MF_SEPARATOR, 0, nullptr);
            for (const auto& profile : {"auto", "phone", "tablet", "large", "maximized"}) {
                std::string body = "{\"package\":" + json::quote(packageName)
                    + ",\"profile\":" + json::quote(profile) + "}";
                std::wstring label = L"Prefer " + utf8ToWide(profile);
                if (label.size() > 7) label[7] = static_cast<wchar_t>(towupper(label[7]));
                addDynamic(sizes, label, {"POST", "/profiles", body, L"Updated the app window profile."});
            }
            AppendMenuW(app, MF_POPUP, reinterpret_cast<UINT_PTR>(sizes), L"Resize window");
            AppendMenuW(app, MF_SEPARATOR, 0, nullptr);
            addDynamic(app, L"Close", {"POST", "/task", taskBody(task, "close"), L"Closed the desktop app."});
            std::wstring label = utf8ToWide(task.at("label").string(packageName));
            if (label.size() > 42) label.resize(42);
            AppendMenuW(tasksMenu, MF_POPUP, reinterpret_cast<UINT_PTR>(app), label.c_str());
            ++count;
            (void) taskId;
            (void) displayId;
        }
    }
    if (!count) AppendMenuW(tasksMenu, MF_STRING | MF_GRAYED, 0, L"No running desktop apps");
    AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(tasksMenu), L"Running apps");
}

void appendWorkspacesMenu(HMENU parent) {
    HMENU workspaces = CreatePopupMenu();
    std::vector<std::string> names{"Work", "Media", "Personal"};
    auto response = agentJson("GET", "/workspaces");
    if (response && response->at("workspaces").is_array()) {
        for (const auto& item : response->at("workspaces").array()) {
            const std::string name = item.at("name").string();
            if (!name.empty() && std::find(names.begin(), names.end(), name) == names.end()) names.push_back(name);
        }
    }
    for (const auto& name : names) {
        HMENU workspace = CreatePopupMenu();
        const std::string nameField = "{\"name\":" + json::quote(name) + "}";
        addDynamic(workspace, L"Open", {"POST", "/workspace/restore", nameField, L"Restored the workspace."});
        addDynamic(workspace, L"Save current layout", {"POST", "/workspace/save", nameField, L"Saved the workspace."});
        addDynamic(workspace, L"Delete", {"POST", "/workspace/delete", nameField, L"Deleted the workspace."});
        AppendMenuW(workspaces, MF_POPUP, reinterpret_cast<UINT_PTR>(workspace), utf8ToWide(name).c_str());
    }
    AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(workspaces), L"Workspaces");
}

void appendNotificationsMenu(HMENU parent) {
    HMENU menu = CreatePopupMenu();
    auto response = agentJson("GET", "/notifications");
    if (!response || !response->at("enabled").boolean()) {
        AppendMenuW(menu, MF_STRING, ID_NOTIFICATION_ACCESS, L"Enable notification access...");
    }
    int count = 0;
    if (response && response->at("notifications").is_array()) {
        for (const auto& item : response->at("notifications").array()) {
            if (count++ == 8) break;
            std::wstring label = utf8ToWide(item.at("title").string());
            if (label.empty()) label = utf8ToWide(item.at("package").string());
            const std::wstring text = utf8ToWide(item.at("text").string());
            if (!text.empty()) label += L" - " + text;
            if (label.size() > 64) label.resize(64);
            const std::string body = "{\"package\":" + json::quote(item.at("package").string()) + "}";
            addDynamic(menu, label, {"POST", "/launch", body, L"Opened the notification app."});
        }
    }
    if (!count) AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, L"No captured notifications");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    addDynamic(menu, L"Clear history", {"POST", "/notifications/clear", "{}", L"Cleared notification history."});
    AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(menu), L"Notifications");
}

void showBalloon(const std::wstring& title, const std::wstring& text) {
    if (!g_ctrl.trayAdded || !g_ctrl.windowsNotifications) return;
    NOTIFYICONDATAW icon{sizeof(icon)};
    icon.hWnd = g_ctrl.window;
    icon.uID = 1;
    icon.uFlags = NIF_INFO;
    wcsncpy_s(icon.szInfoTitle, title.c_str(), _TRUNCATE);
    wcsncpy_s(icon.szInfo, text.c_str(), _TRUNCATE);
    icon.dwInfoFlags = NIIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &icon);
}

void pollNotifications() {
    auto response = agentJson("GET", "/notifications");
    if (!response || !response->at("notifications").is_array()) return;
    long long newest = g_ctrl.latestNotification;
    const json::Value* fresh = nullptr;
    for (const auto& item : response->at("notifications").array()) {
        const long long posted = item.at("postedAt").integer64();
        if (posted > newest) { newest = posted; fresh = &item; }
    }
    if (g_ctrl.notificationsInitialized && fresh) {
        showBalloon(utf8ToWide(fresh->at("title").string("Android notification")), utf8ToWide(fresh->at("text").string()));
    }
    g_ctrl.notificationsInitialized = true;
    g_ctrl.latestNotification = newest;
}

// The Android agent provides a bounded long-poll feed.  This keeps Windows in
// charge of reconciliation without turning the UI thread into a task-polling
// loop. The legacy notification/task queries remain as compatibility fallbacks.
void pollHostEvents() {
    if (g_ctrl.serial.empty()) return;
    bool expected = false;
    if (!g_ctrl.hostEventPollInFlight.compare_exchange_strong(expected, true)) return;
    const long long cursor = g_ctrl.hostEventCursor.load();
    std::thread([cursor]() {
        bool displayTopologyChanged = false;
        try {
            const std::string path = "/api/v1/events?cursor=" + std::to_string(cursor);
            const auto response = agentRequest(
                "GET", path.c_str(), {}, 4'500);
            if (!response.empty()) {
                const json::Value document = json::parse(response);
                g_ctrl.hostEventCursor.store(document.at("cursor").integer64(cursor));
                if (document.at("events").is_array()) {
                    for (const auto& event : document.at("events").array()) {
                        const std::string type = event.at("type").string();
                        if (type == "display-added" || type == "display-changed" || type == "display-removed") {
                            displayTopologyChanged = true;
                        }
                    }
                }
            }
        } catch (...) {
            // The next bounded poll resynchronizes after a USB reconnect or an
            // older agent that does not yet implement the v1 event endpoint.
        }
        g_ctrl.hostEventPollInFlight.store(false);
        if (displayTopologyChanged && g_ctrl.window) PostMessageW(g_ctrl.window, WM_HOST_EVENT, 0, 0);
    }).detach();
}

void pullExports() {
    if (g_ctrl.serial.empty()) return;
    auto response = agentJson("GET", "/exports");
    if (!response || !response->at("exports").is_array()) return;
    const auto directory = knownFolder(FOLDERID_Downloads, L".") / L"RewriteDEX";
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    for (const auto& item : response->at("exports").array()) {
        const std::string name = item.at("name").string();
        const std::string remote = item.at("path").string();
        if (name.empty() || remote.empty() ||
            std::filesystem::path(utf8ToWide(name)).filename().wstring() != utf8ToWide(name)) continue;
        runAdb(L"-s " + g_ctrl.serial + L" pull " + quote(utf8ToWide(remote)) + L" " + quote((directory / utf8ToWide(name)).wstring()));
        if (std::filesystem::exists(directory / utf8ToWide(name))) {
            agentRequest("POST", "/exports/ack", "{\"name\":" + json::quote(name) + "}");
            showBalloon(L"RewriteDEX export", utf8ToWide(name) + L" saved to Windows Downloads.");
        }
    }
}

void showDiagnostics() {
    auto response = agentJson("GET", "/status");
    if (!response) {
        MessageBoxW(g_ctrl.window, L"The RewriteDEX agent is not responding.", L"RewriteDEX diagnostics", MB_OK | MB_ICONWARNING);
        return;
    }
    std::wostringstream text;
    text << L"Device: " << utf8ToWide(response->at("device").string()) << L"\n"
         << L"Android SDK: " << response->at("sdk").integer() << L"\n"
         << L"Agent: " << utf8ToWide(response->at("agentVersion").string()) << L"\n"
         << L"Root: " << (response->at("root").boolean() ? L"ready" : L"not granted") << L"\n"
         << L"Task tracking: " << (response->at("taskTracking").boolean() ? L"ready" : L"unavailable") << L"\n"
         << L"Notification access: " << (response->at("notificationAccess").boolean() ? L"enabled" : L"disabled") << L"\n"
         << L"Desktop display: " << response->at("desktopDisplayId").integer() << L"\n"
         << L"Transport: " << (g_ctrl.scrcpyProcess ? L"running" : L"stopped");
    MessageBoxW(g_ctrl.window, text.str().c_str(), L"RewriteDEX diagnostics", MB_OK | MB_ICONINFORMATION);
}

void openLogs() {
    const auto logPath = moduleDirectory() / L"scrcpy-session.log";
    if (std::filesystem::exists(logPath)) {
        ShellExecuteW(g_ctrl.window, L"open", logPath.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    } else {
        MessageBoxW(g_ctrl.window, L"No scrcpy session log found.", L"RewriteDEX logs", MB_OK | MB_ICONINFORMATION);
    }
}

void exportDiagnostics() {
    const auto dir = knownFolder(FOLDERID_Downloads, L".") / L"RewriteDEX";
    std::error_code err;
    std::filesystem::create_directories(dir, err);
    SYSTEMTIME time;
    GetLocalTime(&time);
    wchar_t name[80];
    swprintf_s(name, L"Diagnostics-%04d%02d%02d-%02d%02d%02d.txt",
        time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
    const auto outPath = dir / name;

    // Gather agent status (UTF-8) and scrcpy log (binary/text) into a single file.
    const std::string status = agentRequest("GET", "/status");
    std::string content = "Agent status:\n";
    content += status.empty() ? "(no agent response)\n" : status + "\n";

    const auto logPath = moduleDirectory() / L"scrcpy-session.log";
    if (std::filesystem::exists(logPath)) {
        std::ifstream lf(logPath, std::ios::binary);
        if (lf) {
            content += "\n--- scrcpy-session.log ---\n";
            content.append((std::istreambuf_iterator<char>(lf)), std::istreambuf_iterator<char>());
        }
    }

    // Write the diagnostics file (UTF-8 content).
    HANDLE file = CreateFileW(outPath.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(file, content.data(), static_cast<DWORD>(content.size()), &written, nullptr);
        CloseHandle(file);
    }

    // Also copy the scrcpy log next to the diagnostics for convenience.
    if (std::filesystem::exists(logPath)) {
        const auto dst = dir / L"scrcpy-session.log";
        std::error_code copyErr;
        std::filesystem::copy_file(logPath, dst, std::filesystem::copy_options::overwrite_existing, copyErr);
    }

    ShellExecuteW(g_ctrl.window, L"open", dir.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

LRESULT CALLBACK settingsWndProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_CREATE: {
        const UINT dpi = g_ctrl.uiDpi;
        const int left = scaleForDpi(16, dpi);
        const int top = scaleForDpi(16, dpi);

        // Polished header
        CreateWindowW(L"STATIC", L"RewriteDEX Settings", WS_CHILD | WS_VISIBLE | SS_LEFT,
            left, top, scaleForDpi(340, dpi), scaleForDpi(22, dpi), window, nullptr, nullptr, nullptr);
        CreateWindowW(L"STATIC", L"Desktop transport & agent preferences", WS_CHILD | WS_VISIBLE,
            left, top + scaleForDpi(22, dpi), scaleForDpi(340, dpi), scaleForDpi(18, dpi), window, nullptr, nullptr, nullptr);

        const int contentTop = top + scaleForDpi(48, dpi);
        CreateWindowW(L"STATIC", L"Stream quality:", WS_CHILD | WS_VISIBLE, left, contentTop, scaleForDpi(200, dpi), scaleForDpi(20, dpi), window, nullptr, nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Responsive", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, left, contentTop + scaleForDpi(22, dpi), scaleForDpi(160, dpi), scaleForDpi(20, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_QUALITY_LOW)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Balanced", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, left, contentTop + scaleForDpi(44, dpi), scaleForDpi(160, dpi), scaleForDpi(20, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_QUALITY_BALANCED)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Maximum", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, left, contentTop + scaleForDpi(66, dpi), scaleForDpi(160, dpi), scaleForDpi(20, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_QUALITY_MAX)), nullptr, nullptr);

        const int left2 = left + scaleForDpi(220, dpi);
        CreateWindowW(L"STATIC", L"Shortcuts:", WS_CHILD | WS_VISIBLE, left2, contentTop, scaleForDpi(200, dpi), scaleForDpi(20, dpi), window, nullptr, nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Windows key shortcuts", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, left2, contentTop + scaleForDpi(22, dpi), scaleForDpi(200, dpi), scaleForDpi(20, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_SHORTCUT_WINDOWS)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Ctrl+Alt shortcuts", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, left2, contentTop + scaleForDpi(44, dpi), scaleForDpi(200, dpi), scaleForDpi(20, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_SHORTCUT_CTRL_ALT)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Shell shortcuts off", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, left2, contentTop + scaleForDpi(66, dpi), scaleForDpi(200, dpi), scaleForDpi(20, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_SHORTCUT_DISABLED)), nullptr, nullptr);

        // Monitor selection and toggles
        const int y2 = contentTop + scaleForDpi(100, dpi);
        CreateWindowW(L"STATIC", L"Monitor:", WS_CHILD | WS_VISIBLE, left, y2, scaleForDpi(100, dpi), scaleForDpi(20, dpi), window, nullptr, nullptr, nullptr);
        HWND combo = CreateWindowW(L"COMBOBOX", nullptr, WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, left + scaleForDpi(80, dpi), y2, scaleForDpi(220, dpi), scaleForDpi(120, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_MONITOR_COMBO)), nullptr, nullptr);
        auto monitors = desktopMonitors();
        for (int i = 0; i < static_cast<int>(monitors.size()); ++i) {
            std::wstring label = L"Windows monitor " + std::to_wstring(i + 1);
            SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        }
        if (!monitors.empty()) SendMessageW(combo, CB_SETCURSEL, g_ctrl.monitorIndex, 0);

        CreateWindowW(L"BUTTON", L"Desktop on every monitor", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, left, y2 + scaleForDpi(30, dpi), scaleForDpi(240, dpi), scaleForDpi(22, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_MONITOR_ALL)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Prefer physical connected display", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, left, y2 + scaleForDpi(56, dpi), scaleForDpi(300, dpi), scaleForDpi(22, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_PHYSICAL_HANDOFF)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Windows notification bridge", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, left, y2 + scaleForDpi(84, dpi), scaleForDpi(240, dpi), scaleForDpi(22, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_WINDOWS_NOTIFICATIONS)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Desktop audio (stream from Pixel)", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, left, y2 + scaleForDpi(110, dpi), scaleForDpi(280, dpi), scaleForDpi(22, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_DESKTOP_AUDIO)), nullptr, nullptr);

        // Apply / Cancel
        const int by = y2 + scaleForDpi(142, dpi);
        CreateWindowW(L"BUTTON", L"Apply", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, left, by, scaleForDpi(100, dpi), scaleForDpi(28, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_SETTINGS_APPLY)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE, left + scaleForDpi(120, dpi), by, scaleForDpi(100, dpi), scaleForDpi(28, dpi), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_SETTINGS_CANCEL)), nullptr, nullptr);

        // Initialize control states from current settings
        // Quality
        SendMessageW(GetDlgItem(window, ID_QUALITY_LOW), BM_SETCHECK, g_ctrl.qualityProfile == 0 ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_QUALITY_BALANCED), BM_SETCHECK, g_ctrl.qualityProfile == 1 ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_QUALITY_MAX), BM_SETCHECK, g_ctrl.qualityProfile == 2 ? BST_CHECKED : BST_UNCHECKED, 0);
        // Shortcuts
        SendMessageW(GetDlgItem(window, ID_SHORTCUT_WINDOWS), BM_SETCHECK, g_ctrl.shortcutPreset == 0 ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_SHORTCUT_CTRL_ALT), BM_SETCHECK, g_ctrl.shortcutPreset == 1 ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_SHORTCUT_DISABLED), BM_SETCHECK, g_ctrl.shortcutPreset == 2 ? BST_CHECKED : BST_UNCHECKED, 0);
        // Toggles
        SendMessageW(GetDlgItem(window, ID_MONITOR_ALL), BM_SETCHECK, g_ctrl.allMonitors ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_PHYSICAL_HANDOFF), BM_SETCHECK, g_ctrl.preferPhysicalDisplay ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_WINDOWS_NOTIFICATIONS), BM_SETCHECK, g_ctrl.windowsNotifications ? BST_CHECKED : BST_UNCHECKED, 0);
        SendMessageW(GetDlgItem(window, ID_DESKTOP_AUDIO), BM_SETCHECK, g_ctrl.audioEnabled ? BST_CHECKED : BST_UNCHECKED, 0);
        return 0;
    }
    case WM_COMMAND: {
        const int id = LOWORD(wParam);
        if (id == ID_SETTINGS_APPLY) {
            // Read and save settings
            if (SendMessageW(GetDlgItem(window, ID_QUALITY_LOW), BM_GETCHECK, 0, 0) == BST_CHECKED) g_ctrl.qualityProfile = 0;
            else if (SendMessageW(GetDlgItem(window, ID_QUALITY_BALANCED), BM_GETCHECK, 0, 0) == BST_CHECKED) g_ctrl.qualityProfile = 1;
            else g_ctrl.qualityProfile = 2;
            saveSetting(L"Quality", g_ctrl.qualityProfile);

            if (SendMessageW(GetDlgItem(window, ID_SHORTCUT_WINDOWS), BM_GETCHECK, 0, 0) == BST_CHECKED) g_ctrl.shortcutPreset = 0;
            else if (SendMessageW(GetDlgItem(window, ID_SHORTCUT_CTRL_ALT), BM_GETCHECK, 0, 0) == BST_CHECKED) g_ctrl.shortcutPreset = 1;
            else g_ctrl.shortcutPreset = 2;
            saveSetting(L"Shortcuts", g_ctrl.shortcutPreset);

            const HWND combo = GetDlgItem(window, ID_MONITOR_COMBO);
            const LRESULT sel = SendMessageW(combo, CB_GETCURSEL, 0, 0);
            if (sel != CB_ERR) { g_ctrl.monitorIndex = static_cast<int>(sel); saveSetting(L"Monitor", g_ctrl.monitorIndex); }
            const bool allMon = SendMessageW(GetDlgItem(window, ID_MONITOR_ALL), BM_GETCHECK, 0, 0) == BST_CHECKED;
            g_ctrl.allMonitors = allMon; saveSetting(L"AllMonitors", g_ctrl.allMonitors ? 1 : 0);
            const bool phys = SendMessageW(GetDlgItem(window, ID_PHYSICAL_HANDOFF), BM_GETCHECK, 0, 0) == BST_CHECKED;
            g_ctrl.preferPhysicalDisplay = phys; saveSetting(L"PhysicalHandoff", g_ctrl.preferPhysicalDisplay ? 1 : 0);
            const bool winNot = SendMessageW(GetDlgItem(window, ID_WINDOWS_NOTIFICATIONS), BM_GETCHECK, 0, 0) == BST_CHECKED;
            g_ctrl.windowsNotifications = winNot; saveSetting(L"WindowsNotifications", g_ctrl.windowsNotifications ? 1 : 0);
            const bool aud = SendMessageW(GetDlgItem(window, ID_DESKTOP_AUDIO), BM_GETCHECK, 0, 0) == BST_CHECKED;
            if (aud != g_ctrl.audioEnabled) {
                g_ctrl.audioEnabled = aud; saveSetting(L"AudioEnabled", g_ctrl.audioEnabled ? 1 : 0);
            }

            updateStatus(L"Applied settings.");
            // Some changes require restarting the desktop stream to take effect.
            if (g_ctrl.scrcpyProcess) restartDesktop();
            DestroyWindow(window);
            return 0;
        } else if (id == ID_SETTINGS_CANCEL) {
            DestroyWindow(window);
            return 0;
        }
        break;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

void showSettingsDialog() {
    // Register a small modal settings window class and create it centered over the control window.
    WNDCLASSW cls{};
    cls.lpfnWndProc = settingsWndProc;
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"RewriteDEXSettingsWindow";
    RegisterClassW(&cls);

    const int width = scaleForDpi(560, g_ctrl.uiDpi);
    const int height = scaleForDpi(340, g_ctrl.uiDpi);
    const POINT cursor{};
    const RECT rc = [&](){ RECT r; GetWindowRect(g_ctrl.window, &r); return r; }();
    const int x = rc.left + (rc.right - rc.left - width) / 2;
    const int y = rc.top + (rc.bottom - rc.top - height) / 2;

    HWND settings = CreateWindowExW(0, cls.lpszClassName, L"RewriteDEX settings", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, x, y, width, height, g_ctrl.window, nullptr, cls.hInstance, nullptr);
    if (!settings) return;
    ShowWindow(settings, SW_SHOW);
}


void restartDesktop() {
    const bool wasRunning = g_ctrl.scrcpyProcess && WaitForSingleObject(g_ctrl.scrcpyProcess, 0) == WAIT_TIMEOUT;
    if (!wasRunning) return;
    g_ctrl.restartingDesktop = true;
    agentRequest("POST", "/session/save", "{}");
    closePixelDesktop();
    launchPixelDesktop();
    g_ctrl.restartingDesktop = false;
}

void captureScreenshot() {
    syncTransportDisplays();
    const int displayId = g_ctrl.primaryDisplayId;
    if (displayId <= 0) {
        updateStatus(L"The desktop display is not ready for a screenshot yet.");
        return;
    }
    const auto directory = knownFolder(FOLDERID_Pictures, L".") / L"RewriteDEX";
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    SYSTEMTIME time{};
    GetLocalTime(&time);
    wchar_t name[80]{};
    swprintf_s(name, L"RewriteDEX-%04d%02d%02d-%02d%02d%02d.png",
        time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
    const std::wstring remote = L"/data/local/tmp/rewritedex-shot.png";
    runAdb(L"-s " + g_ctrl.serial + L" shell screencap -p -d " + std::to_wstring(displayId) + L" " + remote);
    runAdb(L"-s " + g_ctrl.serial + L" pull " + remote + L" " + quote((directory / name).wstring()));
    runAdb(L"-s " + g_ctrl.serial + L" shell rm " + remote);
    updateStatus(std::filesystem::exists(directory / name)
        ? L"Saved the desktop screenshot to Pictures\\RewriteDEX."
        : L"Could not capture the desktop screenshot.");
}

void showTrayMenu() {
    POINT cursor{};
    GetCursorPos(&cursor);
    g_ctrl.dynamicActions.clear();
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, ID_TRAY_SHOW, L"Show RewriteDEX");
    AppendMenuW(menu, MF_STRING, ID_TRAY_START, L"Open Pixel desktop");
    if (g_ctrl.scrcpyProcess) {
        AppendMenuW(menu, MF_STRING, ID_CLOSE_FOCUSED_APP, L"Close focused app\tWin+W");
        AppendMenuW(menu, MF_STRING, ID_TRAY_STOP, L"Close Pixel desktop");
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    appendTasksMenu(menu);
    appendWorkspacesMenu(menu);
    appendNotificationsMenu(menu);

    HMENU pixel = CreatePopupMenu();
    AppendMenuW(pixel, MF_STRING, ID_NOTIFICATIONS, L"Notification shade");
    AppendMenuW(pixel, MF_STRING, ID_QUICK_SETTINGS, L"Quick settings");
    AppendMenuW(pixel, MF_STRING, ID_AUDIO_OUTPUT, L"Audio output");
    AppendMenuW(pixel, MF_STRING, ID_WALLPAPER_NEXT, L"Next background");
    AppendMenuW(pixel, MF_STRING, ID_PHONE_CONTROL, L"Use phone as touchpad");
    AppendMenuW(pixel, MF_STRING, ID_AGENT_SETTINGS, L"RewriteDEX agent settings (on Pixel)");
    AppendMenuW(pixel, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(pixel, MF_STRING, ID_WIDGETS_SHOW, L"Show info widgets");
    AppendMenuW(pixel, MF_STRING, ID_WIDGETS_HIDE, L"Hide info widgets");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(pixel), L"Pixel controls");

    HMENU input = CreatePopupMenu();
    AppendMenuW(input, MF_STRING, ID_KEYBOARD_DESKTOP, L"Desktop on-screen keyboard");
    AppendMenuW(input, MF_STRING, ID_KEYBOARD_PHYSICAL, L"Physical keyboard only");
    AppendMenuW(input, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(input, MF_STRING | (g_ctrl.shortcutPreset == 0 ? MF_CHECKED : 0), ID_SHORTCUT_WINDOWS, L"Windows key shortcuts");
    AppendMenuW(input, MF_STRING | (g_ctrl.shortcutPreset == 1 ? MF_CHECKED : 0), ID_SHORTCUT_CTRL_ALT, L"Ctrl+Alt shortcuts");
    AppendMenuW(input, MF_STRING | (g_ctrl.shortcutPreset == 2 ? MF_CHECKED : 0), ID_SHORTCUT_DISABLED, L"Shell shortcuts off");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(input), L"Keyboard and input");

    HMENU quality = CreatePopupMenu();
    AppendMenuW(quality, MF_STRING | (g_ctrl.qualityProfile == 0 ? MF_CHECKED : 0), ID_QUALITY_LOW, L"Responsive");
    AppendMenuW(quality, MF_STRING | (g_ctrl.qualityProfile == 1 ? MF_CHECKED : 0), ID_QUALITY_BALANCED, L"Balanced");
    AppendMenuW(quality, MF_STRING | (g_ctrl.qualityProfile == 2 ? MF_CHECKED : 0), ID_QUALITY_MAX, L"Maximum quality");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(quality), L"Stream quality");

    HMENU displays = CreatePopupMenu();
    const auto monitors = desktopMonitors();
    for (int i = 0; i < static_cast<int>(monitors.size()); ++i) {
        addDynamic(displays, L"Windows monitor " + std::to_wstring(i + 1),
            {"LOCAL", "monitor:" + std::to_string(i), "", L"Changed the desktop monitor."},
            MF_STRING | (!g_ctrl.allMonitors && i == g_ctrl.monitorIndex ? MF_CHECKED : 0));
    }
    AppendMenuW(displays, MF_STRING | (g_ctrl.allMonitors ? MF_CHECKED : 0), ID_MONITOR_ALL, L"Desktop on every monitor");
    AppendMenuW(displays, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(displays, MF_STRING | (g_ctrl.preferPhysicalDisplay ? MF_CHECKED : 0), ID_PHYSICAL_HANDOFF, L"Prefer physical connected display");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(displays), L"Displays");

    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | (g_ctrl.recording ? MF_CHECKED : 0), ID_RECORDING, L"Record next/current session");
    AppendMenuW(menu, MF_STRING, ID_SCREENSHOT, L"Save screenshot");
    AppendMenuW(menu, MF_STRING, ID_OPEN_EXPORTS, L"Open received files");
    AppendMenuW(menu, MF_STRING | (g_ctrl.windowsNotifications ? MF_CHECKED : 0), ID_WINDOWS_NOTIFICATIONS, L"Windows notification bridge");
    AppendMenuW(menu, MF_STRING | (g_ctrl.audioEnabled ? MF_CHECKED : 0), ID_DESKTOP_AUDIO, L"Desktop audio (stream from Pixel)");
    AppendMenuW(menu, MF_STRING, ID_DIAGNOSTICS, L"Diagnostics");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, ID_TRAY_QUIT, L"Quit RewriteDEX");
    SetForegroundWindow(g_ctrl.window);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, g_ctrl.window, nullptr);
    DestroyMenu(menu);
}

LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_CREATE:
        g_ctrl.uiDpi = GetDpiForWindow(window);
        CreateWindowW(L"BUTTON", L"Refresh", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            scaleForDpi(24, g_ctrl.uiDpi), scaleForDpi(116, g_ctrl.uiDpi),
            scaleForDpi(100, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_REFRESH)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Open desktop", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
            scaleForDpi(134, g_ctrl.uiDpi), scaleForDpi(116, g_ctrl.uiDpi),
            scaleForDpi(120, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_DESKTOP)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Settings", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            scaleForDpi(264, g_ctrl.uiDpi), scaleForDpi(116, g_ctrl.uiDpi),
            scaleForDpi(90, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_SETTINGS)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Quick settings", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            scaleForDpi(364, g_ctrl.uiDpi), scaleForDpi(116, g_ctrl.uiDpi),
            scaleForDpi(112, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_QUICK_SETTINGS)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Android apps", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
            scaleForDpi(24, g_ctrl.uiDpi), scaleForDpi(160, g_ctrl.uiDpi),
            scaleForDpi(140, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_HOST_LAUNCHER)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Windows workspaces", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            scaleForDpi(174, g_ctrl.uiDpi), scaleForDpi(160, g_ctrl.uiDpi),
            scaleForDpi(170, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_HOST_WORKSPACES)), nullptr, nullptr);
        CreateWindowW(L"BUTTON", L"Focus Android desktop", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            scaleForDpi(354, g_ctrl.uiDpi), scaleForDpi(160, g_ctrl.uiDpi),
            scaleForDpi(170, g_ctrl.uiDpi), scaleForDpi(32, g_ctrl.uiDpi),
            window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_FOCUS_DESKTOP)), nullptr, nullptr);
        PostMessageW(window, WM_REFRESH_DEVICE, 0, 0);
        return 0;
    case WM_REFRESH_DEVICE:
        refreshDevice();
        if (g_ctrl.startDesktop && !g_ctrl.serial.empty()) {
            g_ctrl.startDesktop = false;
            PostMessageW(window, WM_COMMAND, ID_DESKTOP, 0);
        }
        return 0;
    case WM_DESKTOP_INPUT:
        // Kept for any external/post-path callers; mouse hook notifies directly.
        notifyDesktopInputAsync(static_cast<int>(wParam));
        return 0;
    case WM_HOST_EVENT:
        syncTransportDisplays();
        return 0;
    case WM_TIMER:
        if (wParam == PROCESS_TIMER && g_ctrl.scrcpyProcess) {
            if (WaitForSingleObject(g_ctrl.scrcpyProcess, 0) == WAIT_OBJECT_0) {
                DWORD exitCode = 0;
                GetExitCodeProcess(g_ctrl.scrcpyProcess, &exitCode);
                stopDesktopTracking();
                // scrcpy often exits 0 on "device disconnected" / encoder loss — do not
                // treat that as the user stopping the desktop. Keep reconnecting until
                // the tray "Stop" path clears desktopRequested.
                if (g_ctrl.desktopRequested && !g_ctrl.restartingDesktop) {
                    updateStatus(
                        L"Desktop transport interrupted (exit " + std::to_wstring(exitCode) +
                        L"). Reconnecting...");
                    SetTimer(window, RECONNECT_TIMER, 1200, nullptr);
                } else {
                    updateStatus(L"Pixel desktop transport stopped.");
                    showControlWindow();
                }
            } else if (!g_ctrl.scrcpyWindow || !IsWindow(g_ctrl.scrcpyWindow)) {
                g_ctrl.scrcpyWindow = findWindowForProcess(g_ctrl.scrcpyPid);
                if (g_ctrl.scrcpyWindow && IsWindow(g_ctrl.scrcpyWindow)) {
                    // First time we see the desktop window after launch — raise it.
                    focusDesktopWindow();
                }
            }
            for (auto& item : g_ctrl.extraTransports) {
                if (item.process && WaitForSingleObject(item.process, 0) == WAIT_OBJECT_0) {
                    restartDesktop();
                    return 0;
                }
                if ((!item.window || !IsWindow(item.window)) && item.process &&
                    WaitForSingleObject(item.process, 0) == WAIT_TIMEOUT) {
                    item.window = findWindowForProcess(item.pid);
                }
            }
            for (auto iterator = g_ctrl.taskSurfaces.begin();
                    iterator != g_ctrl.taskSurfaces.end();) {
                if (!iterator->process
                        || WaitForSingleObject(iterator->process, 0) == WAIT_OBJECT_0) {
                    if (iterator->process) CloseHandle(iterator->process);
                    iterator = g_ctrl.taskSurfaces.erase(iterator);
                    continue;
                }
                if (!iterator->window || !IsWindow(iterator->window)) {
                    iterator->window = findWindowForProcess(iterator->pid);
                }
                ++iterator;
            }
            const bool needsDisplaySync = g_ctrl.primaryDisplayId == 0 ||
                std::any_of(g_ctrl.extraTransports.begin(), g_ctrl.extraTransports.end(), [](const auto& item) {
                    return item.displayId == 0;
                });
            if (needsDisplaySync) syncTransportDisplays();
        } else if (wParam == SESSION_TIMER) {
            agentRequest("POST", "/session/save", "{}");
        } else if (wParam == EXPORT_TIMER) {
            pollHostEvents();
            pollNotifications();
            pullExports();
        } else if (wParam == RECONNECT_TIMER) {
            KillTimer(window, RECONNECT_TIMER);
            refreshDevice();
            if (g_ctrl.desktopRequested && !g_ctrl.serial.empty()) launchPixelDesktop();
        }
        return 0;
    case WM_TRAY:
        if (lParam == WM_LBUTTONUP) toggleControlWindow();
        if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU) showTrayMenu();
        return 0;
    case WM_COMMAND:
        if (const auto found = g_ctrl.dynamicActions.find(LOWORD(wParam)); found != g_ctrl.dynamicActions.end()) {
            const auto action = found->second;
            if (action.method == "LOCAL" && action.path.rfind("monitor:", 0) == 0) {
                g_ctrl.monitorIndex = std::max(0, std::stoi(action.path.substr(8)));
                g_ctrl.allMonitors = false;
                saveSetting(L"Monitor", g_ctrl.monitorIndex);
                saveSetting(L"AllMonitors", 0);
                restartDesktop();
                updateStatus(action.success);
            } else if (action.method == "LOCAL" && action.path.rfind("pin:", 0) == 0) {
                if (g_ctrl.hostWorkspace) {
                    g_ctrl.hostWorkspace->togglePinned(action.path.substr(4));
                    g_ctrl.hostWorkspace->save();
                }
                updateStatus(action.success);
            } else if (action.method == "LOCAL" && action.path.rfind("workspace:", 0) == 0) {
                if (g_ctrl.hostWorkspace) {
                    g_ctrl.hostWorkspace->selectWorkspace(action.selectedWorkspace);
                    g_ctrl.hostWorkspace->save();
                }
                updateStatus(action.success);
            } else if (action.method == "LOCAL" && action.path.rfind("task-surface:", 0) == 0) {
                const std::string encoded = action.path.substr(std::strlen("task-surface:"));
                const size_t separator = encoded.find(':');
                const bool valid = separator != std::string::npos
                    && startTaskSurface(
                        std::stoi(encoded.substr(0, separator)),
                        std::stoi(encoded.substr(separator + 1)),
                        action.launchedPackage);
                if (!valid) {
                    updateStatus(L"Could not open the native Android task surface.");
                }
            } else if (action.method == "LOCAL" &&
                    action.path.rfind("task-surface-focus:", 0) == 0) {
                const int taskId = std::stoi(
                    action.path.substr(std::strlen("task-surface-focus:")));
                updateStatus(focusTaskSurface(taskId)
                    ? action.success
                    : L"The native Android task surface is no longer running.");
            } else if (action.method == "LOCAL" &&
                    action.path.rfind("task-surface-close:", 0) == 0) {
                const int taskId = std::stoi(
                    action.path.substr(std::strlen("task-surface-close:")));
                updateStatus(closeTaskSurface(taskId)
                    ? action.success
                    : L"The native Android task surface was already closed.");
            } else {
                const auto response = agentRequest(action.method.c_str(), action.path.c_str(), action.body);
                const bool succeeded = agentOk(response);
                if (succeeded && g_ctrl.hostWorkspace) {
                    if (!action.launchedPackage.empty()) g_ctrl.hostWorkspace->recordLaunch(action.launchedPackage);
                    if (!action.selectedWorkspace.empty()) g_ctrl.hostWorkspace->selectWorkspace(action.selectedWorkspace);
                    g_ctrl.hostWorkspace->save();
                }
                updateStatus(succeeded ? action.success : L"The Pixel agent could not complete that action.");
            }
            return 0;
        }
        switch (LOWORD(wParam)) {
        case ID_REFRESH: PostMessageW(window, WM_REFRESH_DEVICE, 0, 0); break;
        case ID_DESKTOP:
        case ID_TRAY_START: launchPixelDesktop(); break;
        case ID_HOST_LAUNCHER: showWindowsLauncher(); break;
        case ID_HOST_WORKSPACES: showHostWorkspaces(); break;
        case ID_FOCUS_DESKTOP: focusDesktopWindow(); break;
        case ID_SETTINGS: showSettingsDialog(); break;
        case ID_NOTIFICATIONS: sendSystemAction("notifications"); break;
        case ID_QUICK_SETTINGS: sendSystemAction("quick-settings"); break;
        case ID_AUDIO_OUTPUT: sendSystemAction("audio-output"); break;
        case ID_WALLPAPER_NEXT: {
            const std::string response = agentRequest("POST", "/wallpaper", "{\"action\":\"next\"}");
            updateStatus(agentOk(response) ? L"Changed the desktop background."
                                           : L"Could not change the desktop background.");
            break;
        }
        case ID_PHONE_CONTROL: sendSystemAction("touchpad"); break;
        case ID_AGENT_SETTINGS: {
            const std::string response = agentRequest("POST", "/system", "{\"action\":\"agent-settings\"}");
            updateStatus(agentOk(response) ? L"Opened RewriteDEX settings on the Pixel."
                                           : L"Could not open agent settings on Pixel.");
            break;
        }
        case ID_WIDGETS_SHOW: {
            const std::string response = agentRequest("POST", "/system", "{\"action\":\"widgets-show\"}");
            updateStatus(agentOk(response) ? L"Info widgets shown on desktop."
                                           : L"Could not show widgets.");
            break;
        }
        case ID_WIDGETS_HIDE: {
            const std::string response = agentRequest("POST", "/system", "{\"action\":\"widgets-hide\"}");
            updateStatus(agentOk(response) ? L"Info widgets hidden."
                                           : L"Could not hide widgets.");
            break;
        }
        case ID_KEYBOARD_DESKTOP: sendSystemAction("keyboard-desktop"); break;
        case ID_KEYBOARD_PHYSICAL: sendSystemAction("keyboard-physical"); break;
        case ID_SNAP_LEFT: sendSystemAction("snap-left"); break;
        case ID_SNAP_RIGHT: sendSystemAction("snap-right"); break;
        case ID_MAXIMIZE_TASK: sendSystemAction("maximize"); break;
        case ID_WINDOW_RESTORE: sendSystemAction("restore"); break;
        case ID_WINDOW_SMALLER: sendSystemAction("smaller"); break;
        case ID_WINDOW_LARGER: sendSystemAction("larger"); break;
        case ID_WINDOW_PHONE: sendSystemAction("phone"); break;
        case ID_WINDOW_TABLET: sendSystemAction("tablet"); break;
        case ID_CLOSE_FOCUSED_APP: {
            const std::string response = agentRequest(
                "POST", "/system", "{\"action\":\"close-focused\"}");
            updateStatus(agentOk(response)
                ? L"Closed the focused desktop app. (Win+W / Ctrl+W / Alt+F4)"
                : L"No focused desktop app to close.");
            break;
        }
        case ID_NOTIFICATION_ACCESS: sendSystemAction("notification-access"); break;
        case ID_DIAGNOSTICS: showDiagnostics(); break;
        case ID_SCREENSHOT: captureScreenshot(); break;
        case ID_OPEN_EXPORTS: {
            const auto directory = knownFolder(FOLDERID_Downloads, L".") / L"RewriteDEX";
            std::error_code error;
            std::filesystem::create_directories(directory, error);
            ShellExecuteW(window, L"open", directory.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
            break;
        }
        case ID_RECORDING:
            g_ctrl.recording = !g_ctrl.recording;
            if (g_ctrl.scrcpyProcess) restartDesktop();
            updateStatus(g_ctrl.recording ? L"Session recording enabled." : L"Session recording disabled.");
            break;
        case ID_WINDOWS_NOTIFICATIONS:
            g_ctrl.windowsNotifications = !g_ctrl.windowsNotifications;
            saveSetting(L"WindowsNotifications", g_ctrl.windowsNotifications ? 1 : 0);
            updateStatus(g_ctrl.windowsNotifications ? L"Windows notifications enabled." : L"Windows notifications disabled.");
            break;
        case ID_DESKTOP_AUDIO:
            g_ctrl.audioEnabled = !g_ctrl.audioEnabled;
            saveSetting(L"AudioEnabled", g_ctrl.audioEnabled ? 1 : 0);
            updateStatus(g_ctrl.audioEnabled ? L"Desktop audio enabled (restart stream)." : L"Desktop audio disabled.");
            if (g_ctrl.scrcpyProcess) restartDesktop();
            break;
        case ID_QUALITY_LOW:
        case ID_QUALITY_BALANCED:
        case ID_QUALITY_MAX:
            g_ctrl.qualityProfile = LOWORD(wParam) - ID_QUALITY_LOW;
            saveSetting(L"Quality", g_ctrl.qualityProfile);
            restartDesktop();
            break;
        case ID_SHORTCUT_WINDOWS:
        case ID_SHORTCUT_CTRL_ALT:
        case ID_SHORTCUT_DISABLED:
            g_ctrl.shortcutPreset = LOWORD(wParam) - ID_SHORTCUT_WINDOWS;
            saveSetting(L"Shortcuts", g_ctrl.shortcutPreset);
            updateStatus(L"Updated the desktop shortcut preset.");
            break;
        case ID_MONITOR_ALL:
            g_ctrl.allMonitors = !g_ctrl.allMonitors;
            saveSetting(L"AllMonitors", g_ctrl.allMonitors ? 1 : 0);
            restartDesktop();
            break;
        case ID_PHYSICAL_HANDOFF:
            g_ctrl.preferPhysicalDisplay = !g_ctrl.preferPhysicalDisplay;
            saveSetting(L"PhysicalHandoff", g_ctrl.preferPhysicalDisplay ? 1 : 0);
            restartDesktop();
            break;
        case ID_TRAY_STOP:
            g_ctrl.desktopRequested = false;
            closePixelDesktop();
            updateStatus(L"Pixel desktop transport stopped.");
            showControlWindow();
            break;
        case ID_TRAY_SHOW: showControlWindow(); break;
        case ID_TRAY_QUIT: DestroyWindow(window); break;
        }
        return 0;
    case WM_CLOSE:
        // X on the control panel must not kill the desktop stream. Hide to tray;
        // only "Quit RewriteDEX" (ID_TRAY_QUIT) destroys the process.
        addTrayIcon();
        ShowWindow(window, SW_HIDE);
        updateStatus(L"RewriteDEX is still running in the tray. Open desktop from the tray menu.");
        return 0;
    case WM_SYSCOMMAND:
        if ((wParam & 0xFFF0) == SC_MINIMIZE) {
            ShowWindow(window, SW_HIDE);
            addTrayIcon();
            return 0;
        }
        break;
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC dc = BeginPaint(window, &paint);
        RECT client{};
        GetClientRect(window, &client);

        // Dark DeX-inspired background
        HBRUSH bgBrush = CreateSolidBrush(RGB(18, 20, 22));
        FillRect(dc, &client, bgBrush);
        DeleteObject(bgBrush);

        // Subtle top accent line (DeX feel)
        HPEN accentPen = CreatePen(PS_SOLID, 2, RGB(138, 180, 248));
        HPEN oldPen = static_cast<HPEN>(SelectObject(dc, accentPen));
        MoveToEx(dc, 0, 0, nullptr);
        LineTo(dc, client.right, 0);
        SelectObject(dc, oldPen);
        DeleteObject(accentPen);

        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(232, 234, 237)); // light gray

        HFONT titleFont = CreateFontW(-scaleForDpi(26, g_ctrl.uiDpi), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, FF_DONTCARE, L"Segoe UI");
        HFONT bodyFont = CreateFontW(-scaleForDpi(14, g_ctrl.uiDpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, FF_DONTCARE, L"Segoe UI");

        HFONT oldFont = static_cast<HFONT>(SelectObject(dc, titleFont));
        SetTextColor(dc, RGB(138, 180, 248)); // accent
        TextOutW(dc, scaleForDpi(24, g_ctrl.uiDpi), scaleForDpi(18, g_ctrl.uiDpi), L"RewriteDEX Workspace", 20);

        // Small tagline
        HFONT smallFont = CreateFontW(-scaleForDpi(11, g_ctrl.uiDpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, FF_DONTCARE, L"Segoe UI");
        SelectObject(dc, smallFont);
        SetTextColor(dc, RGB(154, 160, 166));
        TextOutW(dc, scaleForDpi(24, g_ctrl.uiDpi), scaleForDpi(46, g_ctrl.uiDpi), L"Windows shell with a connected Android runtime", 46);
        DeleteObject(smallFont);

        SelectObject(dc, bodyFont);
        SetTextColor(dc, RGB(232, 234, 237));
        DeleteObject(titleFont);

        RECT statusRect{scaleForDpi(24, g_ctrl.uiDpi), scaleForDpi(72, g_ctrl.uiDpi),
            client.right - scaleForDpi(24, g_ctrl.uiDpi), scaleForDpi(110, g_ctrl.uiDpi)};
        DrawTextW(dc, g_ctrl.status.c_str(), static_cast<int>(g_ctrl.status.size()), &statusRect,
            DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS);

        // Bottom separator line above buttons
        HPEN sepPen = CreatePen(PS_SOLID, 1, RGB(42, 48, 54));
        oldPen = static_cast<HPEN>(SelectObject(dc, sepPen));
        MoveToEx(dc, scaleForDpi(20, g_ctrl.uiDpi), scaleForDpi(126, g_ctrl.uiDpi), nullptr);
        LineTo(dc, client.right - scaleForDpi(20, g_ctrl.uiDpi), scaleForDpi(126, g_ctrl.uiDpi));
        SelectObject(dc, oldPen);
        DeleteObject(sepPen);

        SelectObject(dc, oldFont);
        DeleteObject(bodyFont);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_DESTROY:
        g_ctrl.desktopRequested = false;
        agentRequest("POST", "/session/save", "{}");
        removeTrayIcon();
        if (g_ctrl.keyboardHook) {
            UnhookWindowsHookEx(g_ctrl.keyboardHook);
            g_ctrl.keyboardHook = nullptr;
        }
        if (g_ctrl.mouseHook) {
            UnhookWindowsHookEx(g_ctrl.mouseHook);
            g_ctrl.mouseHook = nullptr;
        }
        closeTaskSurfaces();
        stopTaskBroker();
        closePixelDesktop();
        if (g_ctrl.scrcpyJob) {
            CloseHandle(g_ctrl.scrcpyJob);
            g_ctrl.scrcpyJob = nullptr;
        }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}
} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR commandLine, int showCommand) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    loadSettings();
    g_ctrl.startDesktop = commandLine && wcsstr(commandLine, L"--start") != nullptr;
    const auto placement = chooseControllerPlacement();
    g_ctrl.uiDpi = placement.dpi;
    g_ctrl.singleInstance = CreateMutexW(nullptr, TRUE, L"Local\\RewriteDEXPixelDesktopController");
    if (!g_ctrl.singleInstance || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (HWND existing = FindWindowW(L"RewriteDEXTransportWindow", nullptr)) {
            // Prefer raising the Pixel desktop; only show the control panel when
            // the user did not ask to start the desktop.
            if (g_ctrl.startDesktop) {
                ShowWindow(existing, SW_RESTORE);
                SetForegroundWindow(existing);
                PostMessageW(existing, WM_COMMAND, ID_DESKTOP, 0);
            } else {
                ShowWindow(existing, SW_RESTORE);
                SetForegroundWindow(existing);
            }
        }
        if (g_ctrl.singleInstance) CloseHandle(g_ctrl.singleInstance);
        return 0;
    }
    g_ctrl.sessionToken = createSessionToken();
    if (g_ctrl.sessionToken.empty()) {
        CloseHandle(g_ctrl.singleInstance);
        return 1;
    }
    g_ctrl.hostWorkspace = std::make_unique<HostWorkspaceState>(
        knownFolder(FOLDERID_LocalAppData, L".") / L"RewriteDEX" / L"host-workspace.json");
    g_ctrl.hostWorkspace->load();

    WNDCLASSW windowClass{};
    windowClass.hInstance = instance;
    windowClass.lpszClassName = L"RewriteDEXTransportWindow";
    windowClass.lpfnWndProc = windowProc;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    windowClass.hbrBackground = CreateSolidBrush(RGB(248, 249, 250));
    RegisterClassW(&windowClass);

    const int clientWidth = scaleForDpi(760, g_ctrl.uiDpi);
    const int clientHeight = scaleForDpi(320, g_ctrl.uiDpi);
    RECT windowRect{0, 0, clientWidth, clientHeight};
    AdjustWindowRectExForDpi(&windowRect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE, 0, g_ctrl.uiDpi);
    const int windowWidth = windowRect.right - windowRect.left;
    const int windowHeight = windowRect.bottom - windowRect.top;
    const int workWidth = placement.work.right - placement.work.left;
    const int workHeight = placement.work.bottom - placement.work.top;
    const int windowX = placement.work.left + std::max(20, (workWidth - windowWidth) / 2);
    const int windowY = placement.work.top + std::max(20, (workHeight - windowHeight) / 5);
    g_ctrl.window = CreateWindowW(
        windowClass.lpszClassName, L"RewriteDEX", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        windowX, windowY, windowWidth, windowHeight, nullptr, nullptr, instance, nullptr);
    ShowWindow(g_ctrl.window, showCommand);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    ReleaseMutex(g_ctrl.singleInstance);
    CloseHandle(g_ctrl.singleInstance);
    return static_cast<int>(message.wParam);
}
