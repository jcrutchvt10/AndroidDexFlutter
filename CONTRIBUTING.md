# Contributing

## Development Setup

1. Install Visual Studio C++ tools, CMake, Ninja, JDK, Android SDK 36, and MSYS2 UCRT64.
2. Enable USB debugging and Android desktop experience on a test Pixel.
3. Run `./build.ps1` from PowerShell.
4. Install the debug agent APK and run `.\launch.ps1` (or the Desktop RewriteDEX shortcut).

## Before Opening a PR

- Keep Android's Launcher3, SystemUI, and WM Shell as the visible shell.
- Do not add host overlays or Qt dependencies.
- Do not commit secrets, build output, logs, device dumps, or debug captures.
- Build the Win32 controller and Android agent.
- Include device/build details for display, input, task, or scrcpy changes.
- Verify an existing phone task and a fresh app both launch on the desktop.
- Verify resizing preserves roughly 700dp on the desktop's short side.
