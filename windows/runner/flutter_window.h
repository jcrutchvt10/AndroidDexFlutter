#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <map>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include "win32_window.h"
#include "window_thumbnail.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> windows_channel_;
  std::map<DWORD, HWND> embedded_windows_;
  bool surfaces_visible_ = true;
   // Borderless-fullscreen state; the pre-fullscreen placement is restored
   // when the mode is toggled off.
   bool fullscreen_ = false;
   WINDOWPLACEMENT saved_placement_ = {};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
