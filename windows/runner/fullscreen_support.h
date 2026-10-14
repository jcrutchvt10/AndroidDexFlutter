#include "flutter_window.h"

#include <cmath>
#include <optional>
#include <string>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Extracts raw PNG bytes from the thumbnail helper, empty on failure.
flutter::EncodableValue CaptureThumbnailValue(HWND child) {
  const std::vector<uint8_t> bytes = window_thumbnail::CaptureToPng(child);
  return flutter::EncodableValue(bytes);
}

// Switches |host| between its saved placement and borderless fullscreen on
// the monitor that currently contains most of the window.
void ApplyFullscreen(HWND host, bool fullscreen, WINDOWPLACEMENT* saved) {
  if (fullscreen) {
    saved->length = sizeof(WINDOWPLACEMENT);
    if (!GetWindowPlacement(host, saved)) return;
    HMONITOR monitor = MonitorFromWindow(
        host, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info = {};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfo(monitor, &info)) return;
    const LONG_PTR style = GetWindowLongPtr(host, GWL_STYLE);
    SetWindowLongPtr(host, GWL_STYLE,
                     style & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
                               WS_MAXIMIZEBOX | WS_SYSMENU));
    SetWindowPos(host, HWND_TOP, info.rcMonitor.left, info.rcMonitor.top,
                 info.rcMonitor.right - info.rcMonitor.left,
                 info.rcMonitor.bottom - info.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  } else {
    const LONG_PTR style = GetWindowLongPtr(host, GWL_STYLE);
    SetWindowLongPtr(host, GWL_STYLE,
                     style | (WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
                              WS_MAXIMIZEBOX | WS_SYSMENU));
    SetWindowPlacement(host, saved);
    SetWindowPos(host, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  }
}

}  // namespace
