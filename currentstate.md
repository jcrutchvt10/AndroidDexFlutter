# Current State: Android-Dex Flutter Windows Host Replica

## End goal

## September 15 reconstruction progress

- Active HomeScreen now renders `lib/home/desktop_screen.dart`.
- Added bundled wallpapers and Samsung typography, blurred glass panels,
  desktop shortcuts, searchable app launcher, clock, device tray, wallpaper
  picker, and a running-app list.
- App tiles launch the bundled RewriteDEX scrcpy 4.1 fork with a dedicated
  1280x720/240 virtual display per app. `--desktop-transport` gives each
  process its own generated `scid` and flex-resizes the Android display to the
  embedded Win32 child window while preserving logical density.
- Thirteen tests pass, including desktop panel interactions at 1280x720 and
  720x600. Analyzer was clean before the final glass Material wrapper fix.
- NativeDesktopWindows now has a Windows method handler: scrcpy windows attach
  to the Flutter view with SetParent, with DPI-scaled bounds and Flutter frames.
  Live Acode video rendered inside the desktop; launcher overlay also verified.
  Startup must wait for a visible nonzero client window before attachment and
  pass --no-window-aspect-ratio-lock to avoid the observed C0000094 crash.
  No scrcpy source modifications were required. Thirteen tests pass; release builds.
- App launch also passes `--no-vd-system-decorations`, so the embedded stream
  contains only the selected Android app instead of Android's status/navigation
  bars and virtual-display taskbar. Live Acode verification passed on a clean
  Flutter process.
- The Flutter host pins `SCRCPY_SERVER_PATH` to the matching fork server and
  packages the fork runtime (including its SDL/FFmpeg dependencies). The
  stock Android-Dex 4.0 executable is retained only as a fallback when the
  fork is unavailable.
- Closing an embedded app now sends a native `WM_CLOSE` first and only force
  terminates after a short timeout, allowing scrcpy to tear down its virtual
  display instead of leaking a stale Android display.
- Still needed: live visual comparison and launch validation, analog clock,
  persistent preferences, embedded app window lifecycle, media/notification
  controls, and the remaining official desktop behaviors.

### Original objective

Build a Flutter/Dart Windows desktop replica of the Android-Dex host in this
repository, using the existing Android-Dex v1.2 APK/JAR artifacts as the Android
backend. The active implementation is the Flutter project at the repository
root (`lib/`, `windows/`, and `pubspec.yaml`). The old `rewritedex-native/`
project is not the active desktop host.

## Verified status (September 14, 2026)

The Flutter/Dart desktop now builds, packages, launches, and completes its
backend boot sequence against a real Pixel 9 Pro XL.

- `flutter analyze lib test`: no issues
- `flutter test`: 9 tests pass
- `flutter build windows`: succeeds
- Packaged executable:
  `build/windows/x64/runner/Release/androiddex_host.exe`
- Live validation confirmed established callback channels owned by the Flutter
  process:
  - JAR TCP: `127.0.0.1:3698`
  - APK WebSocket: `127.0.0.1:3699`
  - Notification TCP: `127.0.0.1:3700`
  - Media TCP: `127.0.0.1:3701`
- The v1.2 APK foreground service and JAR `app_process` runtime remained alive
  after the handshakes.

## Completed foundation

### Flutter host and packaging

- Repo-local Flutter SDK: `tools/flutter` (Flutter 3.47.4, Dart 3.13.3)
- Windows Flutter app name: `androiddex_host`
- Material 3 boot and desktop shell in `lib/app.dart`, `lib/boot/`, and
  `lib/home/`
- `host_bundle/` contains the Android-Dex v1.2 APK, JARs, ADB runtime, scrcpy
  runtime, and original Flutter data
- `windows/CMakeLists.txt` installs the complete `host_bundle` beside the
  Flutter executable. This is required because Flutter asset packaging filters
  executable, DLL, and APK sidecars.
- `AppPaths` resolves both repository development layout and packaged Windows
  layout.
- ADB resolves to `host_bundle/adb-windows/adb.exe`, where its runtime DLLs are
  present. The top-level bundled `adb.exe` cannot run by itself.

### Protocol and state layer

- Manual v1.2 JSON model in `lib/core/android_core_messages.dart`
- Known message types include `jar.hello`, `apk.hello`, `state_update`,
  `battery_small`, `battery_update`, `volume_update`, and `apk.permissions`
- Unknown v1.2 messages remain parseable rather than failing enum decoding
- Flat v1.2 payloads are supported:
  - `battery_small` fields are top-level
  - `apk.permissions` fields are top-level
  - `states` is accepted as the v1.2 JSON object (with legacy list tolerance)
- `AndroidCore` applies battery, volume, device-state, and permission telemetry
  defensively without null assertion crashes.
- `AndroidCore.refreshApps()` requests the installed-app catalog from the live
  APK channel, parses the response, and exposes sorted app metadata to the UI.

### Host servers

- `JarServer`: newline-delimited TCP on `3698`
  - handles multiple messages received in one socket chunk
  - marks connected only after `jar.hello`
- `ApkServer`: WebSocket on `3699`
  - accepts the v1.2 root path `/` and the prototype alias `/apk`
  - WebSocket compression is disabled because the v1.2 OkHttp client rejects
    the negotiated `Sec-WebSocket-Extensions` response
  - marks connected only after `apk.hello`
- Media and notification TCP servers keep clients connected and consume
  newline-delimited messages instead of immediately closing sockets
- All server clients are closed during disposal
- Both JAR and APK channels support outbound JSON commands with request IDs,
  correlated responses, timeouts, and disconnect cleanup.

### Desktop app catalog

- The home-screen Apps action opens a Flutter modal app grid.
- The grid refreshes from the connected v1.2 APK using `get_all_apps`.
- App labels, package names, and base64 icons are presented by the Flutter/Dart
  desktop host; this is not implemented in `rewritedex-native/`.

### ADB boot orchestration

`lib/services/boot_service.dart` now performs the working sequence:

1. Start ADB and check its result.
2. Require exactly one authorized online device.
3. Remove obsolete `tcp:8457` reverse mappings from older host builds.
4. Run a separate `adb reverse` command for ports 3698, 3699, 3700, and 3701.
5. Start the four Flutter-hosted protocol servers.
6. Stop a stale Android-Dex JAR runtime.
7. Push `androiddex.jar`.
8. Launch it with `app_process` and
   `com.shrey.androiddex.server.Main`.
9. Check/install the real package `com.shrey.androiddex`.
10. Start
    `com.shrey.androiddex/.init_start_server.ServerStartService`.
11. Wait for real `jar.hello` and `apk.hello` messages.
12. Unlock the Flutter desktop after both handshakes.

Port `8457` must not be reversed: the APK binds it locally on Android for JAR
command forwarding.

### Automated coverage

- `test/android_core_messages_test.dart`
  - flat battery payload and state parsing
  - flat permission report and handshake parsing
  - unknown event tolerance
- `test/boot_service_test.dart`
  - authorized device parsing
  - one ADB invocation per reverse mapping
- `test/host_servers_test.dart`
  - v1.2 root WebSocket handshake
  - JAR handshake and multi-line framing
  - outbound APK and JAR command delivery
- `test/widget_test.dart`
  - Flutter application smoke test

## Important implementation facts learned from the v1.2 artifacts

- APK application ID: `com.shrey.androiddex`
- Foreground service:
  `com.shrey.androiddex.init_start_server.ServerStartService`
- APK callback URL: `ws://127.0.0.1:3699` (root path)
- JAR entry point: `com.shrey.androiddex.server.Main`
- APK local JAR-forwarding listener: Android port `8457`
- Media and notification services use newline-delimited TCP callback sockets
  on 3701 and 3700.

## Next milestone

The highest-value next task is launching an app selected from the live Flutter
catalog into a scrcpy-backed Android window:

1. Send the selected package through the JAR `app.start_on_display` flow.
2. Launch the bundled scrcpy runtime for that Android display.
3. Embed or manage the scrcpy native window from the Flutter Windows runner.
4. Build per-app window lifecycle, taskbar, and recents behavior around it.
5. Replace the remaining home-screen action stubs with live panels.
6. Add disconnect detection and automatic reconnection after the core replica
   workflow is functional.

Before implementing those screens, preserve the currently verified boot and
handshake tests. Do not switch work back to `rewritedex-native/`.
