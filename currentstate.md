# Current State: Android-Dex Flutter Windows Host Replica

## End goal

## September 20 robustness pass

- **Dead controls fixed in the device panel.** Torch was sending
  `wifi.get_details` (a read command — no torch wire command exists in the
  v1.2 artifacts; the `flashlightOn/Off` strings are camera resources), so the
  tile was removed. Brightness now uses a real `shell` `settings put system
  screen_brightness` command with session state, and "copy clipboard from
  device" performs the actual `clipboard.text` round-tr instead of showing a
  fake success snackbar.
- **`shell` JAR passthrough documented** (`docs/HOST_ARCHITECTURE.md`):
  verified against the v1.2 JAR (3 literals + `Runtime.exec`); game-mode input
  and panel shell commands are centralized on `DexProtocol.jarShell`.
- **Robustness.** Every ADB invocation is bounded by `adbTimeout` (20 s); host
  servers replace a stale active client instead of silently interleaving two
  senders (and only the *active* socket fires disconnect callbacks);
  `settings.json` writes are atomic (temp + rename) and debounced (400 ms);
  handshake waits use completers with no polling; a second
  `initializeSystem` while an attempt is in flight reports in-flight state
  instead of silently no-oping; the boot screen disables Retry while running.
- **scrcpy knobs exposed in settings**: virtual-display size/dpi, fps, codec,
  bitrate, stay-awake, and screen-off-while-streaming, all threaded through
  `ScrcpyArguments` into app launch. A scrcpy crash now keeps the last stderr
  lines in the dev log and offers a Relaunch button on the window banner.
- **Window shell polish.** Edge/corner resize affordances, drag-to-top snap,
  redundant native `position` calls skipped (only real geometry changes are
  forwarded), per-window surface visibility on panel open, game-mode
  coordinates mapped from Android display space with clamping.
- **Error taxonomy.** Reinstall-class failures (missing bundle/APK/JAR) no
  longer offer the device picker (`isReinstallError` guards
  `isConnectionError`).
- Cleanup: duplicate `notification_toast_overlay.dart` merged into `lib/home/`,
  `analysis_options.yaml` excludes the vendored `tools/flutter` SDK so plain
  `flutter analyze` works, `GameProfileStore` logs via `DevLog`.
- **33 tests pass** (`flutter test`), including a fake-server boot-failure
  harness (`test/boot_service_failures_test.dart`) and scrcpy argument
  coverage. The embedded-window drag test now drives a real multi-move
  gesture and asserts the window actually moved (the old 20 px drag never
  crossed the 36 px pan slop and passed vacuously).
- CI archives the Windows Release output as a build artifact.
## September 15 reconstruction progress

- Active HomeScreen renders `lib/home/desktop_screen.dart`.
- Added bundled wallpapers and Samsung typography, blurred glass panels,
  desktop shortcuts, searchable app launcher, clock, device tray, wallpaper
  picker, and a running-app list.
- App tiles launch the bundled RewriteDEX scrcpy 4.1 fork with a dedicated
  1280x720/240 virtual display per app. `--desktop-transport` gives each
  process its own generated `scid` and flex-resizes the Android display to the
  embedded Win32 child window while preserving logical density.
- **24 tests pass** (`flutter test`), including desktop panel interactions at
  1280x720 and 720x600. `flutter analyze lib test` is clean. Release builds
  succeed (`flutter build windows`).- NativeDesktopWindows has a Windows method handler: scrcpy windows attach
  to the Flutter view with SetParent, with DPI-scaled bounds and Flutter frames.
  Live Acode video rendered inside the desktop; launcher overlay also verified.
  Startup must wait for a visible nonzero client window before attachment and
  pass --no-window-aspect-ratio-lock to avoid the observed C0000094 crash.
- App launch also passes `--no-vd-system-decorations`, so the embedded stream
  contains only the selected Android app instead of Android's status/navigation
  bars and virtual-display taskbar.
- The Flutter host pins `SCRCPY_SERVER_PATH` to the matching fork server and
  packages the fork runtime (including its SDL/FFmpeg dependencies).
- Closing an embedded app sends a native `WM_CLOSE` first and only force
  terminates after a short timeout.

### Parity work added this pass

- **Media + notification channels are wired.** The two callback ports (3700,
  3701) now feed `MediaDataManager` / `NotificationDataManager` and the new
  Media Center and Notification Center panels. Verified against the v1.2 bin:
  the channels are plain newline-delimited TCP, not WebSocket (see
  `docs/HOST_ARCHITECTURE.md`).
- **Device manager.** `DeviceManager` supports USB and Wi-Fi targets
  (`--usb` / `ip`, `adb connect`), and the boot screen offers the ADB Manager
  dialog on connection failure instead of freezing.
- **Reconnection.** `ReconnectionManager` executes two-phase auto-heal and a
  `Reconnecting` overlay blocks the desktop during recovery.
- **Two-tier errors.** `AndroidDexError` keeps raw output in `DevLog` while the
  UI shows plain-English recovery guidance; `ConnectionFailure` reveals the
  device-picker button.
- **Window shell.** Each app window supports drag, resize, snap, maximize and
  minimize via `WindowManager`; the taskbar lists running windows; Recents uses
  `WindowThumbnailService` captures (falling back to the app icon).
- **Keyboard shortcuts + fullscreen.** `Ctrl+F`/`F11`, `Esc`, `Ctrl+W/M`,
  `Ctrl+Tab`, `Ctrl+Shift+←/→/↑/↓`, `Ctrl+Alt+↑/↓/←/→`, `Ctrl+/` help overlay.

## Verified status (metadata)

- `flutter analyze`: no issues
- `flutter test`: 33 tests pass
- `flutter build windows`: succeeds
- Packaged executable:
  `build/windows/x64/runner/Release/androiddex_host.exe`
- Callback channels owned by the Flutter process:
  - JAR TCP: `127.0.0.1:3698`
  - APK WebSocket: `127.0.0.1:3699`
  - Notification TCP: `127.0.0.1:3700`
  - Media TCP: `127.0.0.1:3701`

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
  - one ADB (reverse) invocation per bridged port; `-d` vs `-s` selectors
- `test/error_messages_test.dart`
  - `AndroidDexError` two-tier contract; raw vs user-facing text
  - `isConnectionError` heuristic
  - tolerant JSON readers (flat and nested shapes)
- `test/channel_managers_test.dart`
  - media channel handshake + now-playing + bare state change
  - notification ring, grouping, removal, bulk resends
- `test/core_services_test.dart`
  - `DeviceManager` USB/Wi-Fi resolution, CLI parsing, IP normalisation
  - `WindowManager` focus order, snap, minimize/restore
  - `setBootError` notifier (regression for the frozen-error-panel bug)
- `test/embedded_app_window_test.dart`
  - native surface attach; real-drag reposition (movement + position call
    asserted); minimize hides the frame
- `test/boot_service_failures_test.dart`
  - clean failure when the host bundle is missing (and no device picker)
  - handshake waiter resolution/timeout; reset fails pending waiters
  - concurrent `initializeSystem` refusal
- `test/scrcpy_arguments_test.dart`
  - display/fps/codec/bitrate/stay-awake/screen-off argument composition
- `test/desktop_screen_test.dart`
  - desktop panels at 1280x720 and 720x600
- `test/host_servers_test.dart`
  - v1.2 root WebSocket handshake; JAR handshake and multi-line framing
  - outbound APK and JAR command delivery
- `test/widget_test.dart`
  - Flutter application smoke test

## Important implementation facts learned from the v1.2 artifacts

- APK application ID: `com.shrey.androiddex`
- Foreground service:
  `com.shrey.androiddex.init_start_server.ServerStartService`
- APK callback URL: `ws://127.0.0.1:3699` (root path) — the only WebSocket
  channel; ports 3700/3701 are plain newline-delimited TCP.
- JAR entry point: `com.shrey.androiddex.server.Main`
- APK local JAR-forwarding listener: Android port `8457` (never reversed)
- JAR commands: `app.start_on_display`, `app.force_stop`, `volume.get_all`
  / `.set`, `display.power.get` / `.set`, `wifi.get_details`,
  `clipboard.text` / `.set` / `.toggle`, `shell` (Runtime.exec passthrough)
- APK commands/events: `get_all_apps`, `apk.permissions.get`, `state.get_all`,
  `apk.hello`, `apk.app_added`, `apk.app_removed`, `apk.app_count`,
  `battery_small`, `battery_update`, `volume_update`

## Next milestone

The per-app window pipeline is built and covered by unit/widget tests; the
remaining validation is **live on a device**:

1. Launch a real app from the catalog and confirm the scrcpy surface embeds
   inside the Flutter-drawn frame (was working before this pass).
2. Exercise snap / maximize / minimize and Recents thumbnails live.
3. Confirm media and notification panels populate from a real device session.
4. Observe the reconnection overlay by unplugging/re-plugging the device.
5. Wire the last two stubs (gaming-mode hotkey is intentionally not
   implemented; see the shortcut help).

Preserve the verified boot/handshake tests; do not switch work back to
`rewritedex-native/`. `package.ps1` and `bootstrap.ps1` now target the Flutter
host. `host_bundle/` **is** committed (`.gitignore` un-ignores it at line 77)
— an earlier revision of this file claimed otherwise.
