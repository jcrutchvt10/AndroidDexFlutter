# RewriteDEX

RewriteDEX presents a Pixel's native Android desktop experience on Windows over
USB. Android Launcher3, SystemUI, and WM Shell own everything visible inside the
desktop; RewriteDEX supplies only transport, desktop-aware resizing, and a
small authenticated device bridge.

There is no Qt shell and no host taskbar painted over Android.

## Architecture

- `rewritedex-native/native-controller`: Qt-free Win32 launcher and tray app
- `rewritedex-native/android-agent`: root-aware Android task/session bridge
- `third_party/scrcpy-fork`: RewriteDEX scrcpy client and server sources
- `third_party/scrcpy`: deployed portable runtime

The scrcpy fork creates a trusted, decorated Android virtual display and keeps
its logical short side near 700dp while the Windows window is resized. Existing
phone tasks are moved to that display when an app uses single-task semantics;
new tasks are launched there with `ActivityOptions`.

## Desktop Features

Right-click the RewriteDEX notification-area icon for the command center:

- focus, close, move, resize, or open a second instance of real Android tasks
- save and restore named Work, Media, and Personal workspaces
- choose responsive, balanced, or maximum-quality streaming
- target one Windows monitor, every monitor, or a native connected display
- switch backgrounds, open Android panels, and use the phone as a touchpad
- record sessions, capture desktop screenshots, and inspect diagnostics
- receive Android shares in `Downloads\RewriteDEX`
- optionally mirror Android notifications into Windows

Drop files or folders onto a desktop window to send them to Android. APK drops
always open Android's package installer for explicit approval. On Android, use
Share > RewriteDEX to Windows to return files to the PC.

The notification bridge is deliberately opt-in. Choose `Notifications > Enable
notification access...` in the tray and approve RewriteDEX on the Pixel.

## Build

Requirements: Windows 10+, Visual Studio C++ tools, CMake, Ninja, JDK, Android
SDK 36, and MSYS2 UCRT64 for rebuilding scrcpy.

```powershell
.\build.ps1
```

Run the local checks after building:

```powershell
.\verify.ps1 -SkipDevice
.\verify.ps1 -ExerciseAgentApi
```

Install the agent once:

```powershell
adb install -r .\rewritedex-native\android-agent\app\build\outputs\apk\debug\app-debug.apk
```

Launch (one binary, one story):

| Entry | Notes |
|---|---|
| Desktop **RewriteDEX** shortcut | Points at the built controller with `--start` |
| `.\launch.ps1` | Canonical launcher (also used by the others) |
| `RewriteDEX.vbs` | Same as `launch.ps1`, no console flash |
| `Launch RewriteDEX.bat` | Thin wrapper around `launch.ps1` |

All start:

`rewritedex-native\build\rewritedex-native.exe --start`

`launch.ps1` stops any other `rewritedex.exe` / off-tree controller so
legacy builds cannot run alongside this one. The controller is a GUI app;
`scrcpy-fork.exe` is spawned without a console window.

The Pixel must have USB debugging and Android's desktop experience enabled.
Root is required for reliable task moves, close/resize commands, and session
restoration. See [the native project documentation](rewritedex-native/README.md)
for protocol and implementation details.

## Opik Observability

The host controller can send metadata-only Opik traces for authenticated calls
to the Android agent. Configure `OPIK_API_KEY`, `OPIK_WORKSPACE`, and
`OPIK_URL_OVERRIDE` in the local ignored `.env`; `launch.ps1` passes them only to
the controller. Traces use the `rewritedex-agent` project and contain the HTTP
method, route, status, and latency—not request bodies, device content, or the
credential. Pointer-movement traffic is excluded.

## Pixel Visuals

RewriteDEX intentionally installs no visual RRO. The tested Android 17 Pixel
SystemUI and Launcher APKs expose no public overlayable desktop resources, so
private-resource theming would be fragile and could destabilize SystemUI.
