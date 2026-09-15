# AndroidDexFlutter

AndroidDexFlutter is a Flutter/Dart Windows desktop host that recreates the
Android-Dex desktop experience and embeds each Android app directly inside the
Flutter window. It uses the Android-Dex v1.2 APK/JAR backend and a bundled
RewriteDEX scrcpy 4.1 runtime for per-app virtual displays and smooth resizing.

The active host lives at the repository root (`lib/`, `windows/`, and
`pubspec.yaml`). The older `rewritedex-native/` tree is retained for reference
but is not used by this Flutter desktop.

## Requirements

- Windows 10 or newer
- Flutter 3.47.4 (Dart 3.13.3) or a compatible newer Flutter SDK
- Visual Studio C++ desktop workload and CMake
- An Android device with USB debugging enabled and ADB authorization accepted

The tested checkout uses a local SDK under `tools/flutter`; that SDK is a local
build cache and is intentionally not committed. Install Flutter separately or
set `FLUTTER_ROOT` to an existing SDK.

## Build and run

From PowerShell at the repository root:

```powershell
$flutter = if ($env:FLUTTER_ROOT) { Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat' } else { 'flutter' }
& $flutter pub get
& $flutter build windows
& .\build\windows\x64\runner\Release\androiddex_host.exe
```

The Windows runner installs `host_bundle/` beside the executable. That bundle
contains the Android-Dex APK/JARs, ADB runtime, Flutter assets, and scrcpy
dependencies, so no separate scrcpy installation is required.

## Verification

```powershell
& $flutter analyze lib test
& $flutter test
```

The host performs the ADB reverse mappings and waits for both Android-Dex
handshakes before enabling the desktop. Selecting an app starts scrcpy with a
dedicated 1280x720 virtual display; the native scrcpy window is attached as a
child of the Flutter window, and closing it tears down the Android display.

## Project layout

- `lib/` — Flutter UI, boot orchestration, protocol models, and app lifecycle
- `windows/` — Win32 embedding and runtime packaging
- `host_bundle/` — Android-Dex backend and portable runtime
- `third_party/scrcpy/` — matching RewriteDEX scrcpy client/server binaries
- `test/` — protocol, boot, server, and widget coverage
- `currentstate.md` — implementation history and validation notes

The companion APK is the Android-Dex package `com.shrey.androiddex`; it is
bundled as `host_bundle/AndroidDex.apk` and installed/started by the boot flow.
