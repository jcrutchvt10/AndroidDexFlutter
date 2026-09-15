#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <cmath>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
        SetFocus(child);
      }
      result->Success(); return;
    }
    if (method == "close") {
      if (child) {
        PostMessage(child, WM_CLOSE, 0, 0);
        embedded_windows_.erase(pid);
      }
      result->Success(); return;
    }
    result->NotImplemented();
  });

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
  for (auto entry : embedded_windows_) if (IsWindow(entry.second)) PostMessage(entry.second, WM_CLOSE, 0, 0);
  embedded_windows_.clear();
  windows_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
