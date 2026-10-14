#include "flutter_window.h"

#include <cmath>
#include <map>
#include <optional>
#include <set>
#include <string>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "fullscreen_support.h"

namespace {

// Embedded scrcpy surfaces currently attached to the Flutter view.
std::set<HWND> g_surfaces;

// System-wide click watcher; see MouseHookProc.
HHOOK g_mouse_hook = nullptr;

// Pointer to the FlutterWindow instance so MouseHookProc can notify Dart
// via the method channel when a surface is clicked.
FlutterWindow* g_flutter_window = nullptr;

// Moves keyboard focus into an embedded Android surface.
//
// A bare SetFocus() fails for a window owned by another process (the surface
// belongs to scrcpy-fork.exe), which is why the runner's "focus" method used
// to be a silent no-op and typing kept landing on the Flutter view instead of
// the Android app. Attaching the two input queues first is what actually
// makes the focus change take effect.
bool FocusSurface(HWND surface) {
  if (surface == nullptr || !IsWindow(surface)) {
    return false;
  }
  const DWORD target_thread = GetWindowThreadProcessId(surface, nullptr);
  const DWORD self_thread = GetCurrentThreadId();
  const BOOL attached =
      target_thread != 0 && target_thread != self_thread &&
      AttachThreadInput(self_thread, target_thread, TRUE);
  const HWND previous = SetFocus(surface);
  if (attached) {
    AttachThreadInput(self_thread, target_thread, FALSE);
  }
  return previous == surface || GetFocus() == surface;
}

// The embedded surface under |point|, or nullptr when the point belongs to
// Flutter's own chrome.
HWND SurfaceFromPoint(POINT point) {
  HWND hit = WindowFromPoint(point);
  while (hit != nullptr) {
    if (g_surfaces.find(hit) != g_surfaces.end()) {
      return hit;
    }
    const HWND parent = GetParent(hit);
    if (parent == nullptr || parent == hit) {
      return nullptr;
    }
    hit = parent;
  }
  return nullptr;
}

// Clicks inside the Android surface must hand it the keyboard.
//
// Mouse routing already reaches the child window, but focus never moves on its
// own (and no message reaches the host window for a click that lands entirely
// on the child), so this low-level hook is what makes the typing follow the click.
//
// It also notifies Dart via the method channel so WindowManager.focus() stays
// in sync with the actual Win32 focus — otherwise Dart thinks the old window
// is focused and the Win32 sibling z-order never updates.
LRESULT CALLBACK MouseHookProc(int code, WPARAM wParam, LPARAM lParam) {
  if (code == HC_ACTION) {
    switch (wParam) {
      case WM_LBUTTONDOWN:
      case WM_RBUTTONDOWN:
      case WM_MBUTTONDOWN:
      case WM_XBUTTONDOWN: {
        const auto* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(lParam);
        HWND surface = SurfaceFromPoint(info->pt);
        if (surface != nullptr) {
          FocusSurface(surface);
          // Notify Dart so WindowManager.focus() tracks the Win32 focus change.
          if (g_flutter_window != nullptr) {
            g_flutter_window->NotifySurfaceClicked(surface);
          }
        }
        break;
      }
      default:
        break;
    }
  }
  return CallNextHookEx(nullptr, code, wParam, lParam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  g_flutter_window = this;

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Clicks on an embedded surface never reach this window, so a low-level
  // mouse hook is what hands the keyboard to the Android app under the cursor.
  if (g_mouse_hook == nullptr) {
    g_mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, &MouseHookProc,
                                     GetModuleHandleW(nullptr), 0);
  }
  windows_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "androiddex/windows",
      &flutter::StandardMethodCodec::GetInstance());
  windows_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("arguments", "Missing window arguments"); return; }
    auto number = [args](const char* key) -> double {
      auto it = args->find(flutter::EncodableValue(key));
      if (it == args->end()) return 0;
      if (auto value = std::get_if<double>(&it->second)) return *value;
      if (auto value = std::get_if<int32_t>(&it->second)) return *value;
      if (auto value = std::get_if<int64_t>(&it->second)) return static_cast<double>(*value);
      return 0;
    };
    const auto method = call.method_name();
    if (method == "visible") {
      auto it = args->find(flutter::EncodableValue("visible"));
      surfaces_visible_ = it != args->end() && std::holds_alternative<bool>(it->second) && std::get<bool>(it->second);
      for (auto entry : embedded_windows_) if (IsWindow(entry.second))
        ShowWindow(entry.second, surfaces_visible_ ? SW_SHOWNA : SW_HIDE);
      result->Success(); return;
    }
    DWORD pid = static_cast<DWORD>(number("process_id"));
    HWND child = nullptr;
    auto found = embedded_windows_.find(pid);
    if (found != embedded_windows_.end() && IsWindow(found->second)) child = found->second;
    if (method == "embed" && !child) {
      struct Search { DWORD pid; HWND window; } search{pid, nullptr};
      EnumWindows([](HWND window, LPARAM param) -> BOOL {
        auto* search = reinterpret_cast<Search*>(param);
        DWORD owner = 0; GetWindowThreadProcessId(window, &owner);
        RECT rect{};
        GetClientRect(window, &rect);
        if (owner == search->pid && GetWindow(window, GW_OWNER) == nullptr &&
            IsWindowVisible(window) && rect.right > 0 && rect.bottom > 0) {
          search->window = window; return FALSE;
        }
        return TRUE;
      }, reinterpret_cast<LPARAM>(&search));
      child = search.window;
      if (child) {
        ShowWindow(child, SW_HIDE);
        auto style = GetWindowLongPtr(child, GWL_STYLE);
        SetWindowLongPtr(
            child, GWL_STYLE,
            (style & ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME |
                       WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU)) |
                WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN);
        auto ex_style = GetWindowLongPtr(child, GWL_EXSTYLE);
        // SDL creates a top-level window. Clear the shell-facing extended
        // styles before parenting it so Windows cannot keep a taskbar/Alt-Tab
        // entry for the transport surface after it becomes a Flutter child.
        SetWindowLongPtr(child, GWL_EXSTYLE,
                         ex_style & ~(WS_EX_APPWINDOW | WS_EX_TOOLWINDOW));
        SetLastError(0);
        HWND previous = SetParent(child, flutter_controller_->view()->GetNativeWindow());
        if (!previous && GetLastError() != 0) {
          PostMessage(child, WM_CLOSE, 0, 0);
          result->Error("embed", "Windows could not attach the Android surface");
          return;
        }
        embedded_windows_[pid] = child;
        // Track the surface so click-to-focus can recognise it.
        g_surfaces.insert(child);
      }
    }
    if (method == "embed" || method == "position") {
      if (child) {
        const double scale = GetDpiForWindow(GetHandle()) / 96.0;
        SetWindowPos(
            child, HWND_TOP,
            static_cast<int>(std::lround(number("x") * scale)),
            static_cast<int>(std::lround(number("y") * scale)),
            static_cast<int>(std::lround(number("width") * scale)),
            static_cast<int>(std::lround(number("height") * scale)),
            SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
        ShowWindow(child, surfaces_visible_ ? SW_SHOWNA : SW_HIDE);
      }
      if (method == "embed") {
        result->Success(flutter::EncodableValue(child != nullptr));
      } else {
        result->Success();
      }
      return;
    }
    if (method == "focus") {
      if (child) {
        BringWindowToTop(child);
        FocusSurface(child);
      }
      result->Success(); return;
    }
    if (method == "close") {
      if (child) {
        PostMessage(child, WM_CLOSE, 0, 0);
        embedded_windows_.erase(pid);
        g_surfaces.erase(child);
      }
      result->Success(); return;
    }
    if (method == "window_visible") {
      if (child) {
        auto it = args->find(flutter::EncodableValue("visible"));
        const bool visible = it != args->end() &&
                             std::holds_alternative<bool>(it->second) &&
                             std::get<bool>(it->second);
        ShowWindow(child, visible ? SW_SHOWNA : SW_HIDE);
      }
      result->Success(); return;
    }
    if (method == "raise") {
      if (child) {
        SetWindowPos(child, HWND_TOP, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                         SWP_NOOWNERZORDER);
        BringWindowToTop(child);
        FocusSurface(child);
      }
      result->Success(); return;
    }
    if (method == "thumbnail") {
      if (child) {
        const std::vector<uint8_t> bytes = window_thumbnail::CaptureToPng(child);
        if (bytes.empty()) {
          result->Success(flutter::EncodableValue(std::vector<uint8_t>()));
        } else {
          result->Success(flutter::EncodableValue(bytes));
        }
      } else {
        result->Success(flutter::EncodableValue(std::vector<uint8_t>()));
      }
      return;
    }
    if (method == "fullscreen") {
      auto it = args->find(flutter::EncodableValue("fullscreen"));
      const bool target = it != args->end() &&
                          std::holds_alternative<bool>(it->second) &&
                          std::get<bool>(it->second);
      if (target != fullscreen_) {
        fullscreen_ = target;
        ApplyFullscreen(GetHandle(), fullscreen_, &saved_placement_);
      }
      result->Success(); return;
    }
    result->NotImplemented();
  });

  // Enable drag-and-drop file support on the host window.
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (g_mouse_hook != nullptr) {
    UnhookWindowsHookEx(g_mouse_hook);
    g_mouse_hook = nullptr;
  }
  g_flutter_window = nullptr;
  g_surfaces.clear();
  for (auto entry : embedded_windows_) if (IsWindow(entry.second)) PostMessage(entry.second, WM_CLOSE, 0, 0);
  embedded_windows_.clear();
  windows_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::NotifySurfaceClicked(HWND surface) {
  if (windows_channel_ == nullptr) return;
  for (auto& entry : embedded_windows_) {
    if (entry.second == surface) {
      windows_channel_->InvokeMethod(
          "surfaceClicked",
          std::make_unique<flutter::EncodableValue>(
              static_cast<int64_t>(entry.first)));
      return;
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Activating the host used to unconditionally focus the Flutter view, which
  // stole the keyboard from an Android surface the user was typing into. When
  // the cursor is over a surface, that surface keeps (or takes) the focus.
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE) {
    POINT point{};
    if (GetCursorPos(&point)) {
      HWND surface = SurfaceFromPoint(point);
      if (surface != nullptr) {
        FocusSurface(surface);
        return 0;
      }
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DROPFILES: {
      // Capture dropped file paths and forward to Dart.
      HDROP drop = reinterpret_cast<HDROP>(wparam);
      UINT file_count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      std::vector<std::string> paths;
      for (UINT i = 0; i < file_count; ++i) {
        UINT path_len = DragQueryFileW(drop, i, nullptr, 0);
        if (path_len == 0) continue;
        std::wstring wide_path(path_len + 1, L'\0');
        DragQueryFileW(drop, i, &wide_path[0], path_len + 1);
        wide_path.resize(path_len);
        // Convert wide string to UTF-8.
        int utf8_len = WideCharToMultiByte(CP_UTF8, 0, wide_path.c_str(),
                                           -1, nullptr, 0, nullptr, nullptr);
        if (utf8_len > 0) {
          std::string utf8_path(utf8_len - 1, '\0');
          WideCharToMultiByte(CP_UTF8, 0, wide_path.c_str(), -1,
                              &utf8_path[0], utf8_len, nullptr, nullptr);
          paths.push_back(utf8_path);
        }
      }
      DragFinish(drop);
      // Forward paths to Dart via the method channel.
      if (windows_channel_ != nullptr && !paths.empty()) {
        flutter::EncodableList encodable_paths;
        for (const auto& p : paths) {
          encodable_paths.push_back(flutter::EncodableValue(p));
        }
        windows_channel_->InvokeMethod(
            "filesDropped",
            std::make_unique<flutter::EncodableValue>(encodable_paths));
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
