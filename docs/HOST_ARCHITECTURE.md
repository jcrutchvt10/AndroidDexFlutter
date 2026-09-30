# AndroidDexFlutter — Host Architecture & Verified Wire Contract

This document pins down the parts of the replica that are easy to get wrong
because the Android-Dex backend is closed-source. Every port, command name and
handshake below was **recovered from the shipped v1.2 artifacts** (`classes*.dex`
inside `host_bundle/AndroidDex.apk` and `host_bundle/androiddex.jar`), not
guessed from documentation.

## Layer model

```
Windows (this host)                 Android device
──────────────────────              ─────────────────────────────
Flutter UI · ADB · servers          Logic Engine (JAR) · Feature Hub (APK)
        ▲  TCP 3698  ◄────────────── JAR  (app_process)
        ▲  WS   3699  ◄───────────── APK  (Kotlin service)
        ▲  TCP  3700  ◄───────────── Notifications
        ▲  TCP  3701  ◄───────────── Media
        ▲  adb reverse tcp:PORT      ─────────────────────────────
```

The Windows side is always the TCP/WebSocket **server**; the two Android
components are **clients that dial back** after boot.

## Callback channels (critical)

| Port  | Transport        | Handshake type        | Payload |
| :---: | :---             | :---                  | :---    |
| 3698  | raw TCP, newline JSON | `jar.hello`      | commands |
| 3699  | WebSocket JSON   | `apk.hello`           | telemetry |
| 3700  | raw TCP, newline JSON | `notification.hello` | notification stream |
| 3701  | raw TCP, newline JSON | `media.hello`     | media session |

> **3700/3701 are NOT WebSocket.** The reference architecture doc labels the
> media/notification channels "WebSocket", but the only `ws://` literal present
> anywhere in the APK is `ws://127.0.0.1:3699`. The media and notification
> clients are plain sockets speaking newline-delimited JSON. The reference doc
> is inaccurate; trust the binary.

> **8457 must never be reversed.** `AndroidDex.apk` binds port 8457 **on the
> device** so the on-device JAR can forward commands to the APK. Reversing it
> breaks the bridge. This host intentionally removes any stale `tcp:8457`
> reverse mapping at boot.

## Command / event vocabulary (verified)

**JAR channel (3698):**

| Command | Notes |
| :---    | :---  |
| `app.start_on_display` | Place an app on a display (used when not routing via scrcpy `--start-app`) |
| `app.force_stop` | Stop an app (used by window close) |
| `volume.get_all` / `volume.set` | Audio stream volume |
| `display.power.get` / `.set` | Screen on/off |
| `wifi.get_details` | Wi-Fi info |
| `clipboard.text` / `.set` / `.toggle` | Clipboard sync |
| `shell` | Passthrough to `Runtime.exec` on device (verified: 3 literals + exec site in the v1.2 JAR). Used for input injection in game mode and `settings put system screen_brightness` in the control panel |

**APK channel (3699):**

| Command / event | Notes |
| :---            | :---  |
| `get_all_apps`  | App list with launcher icons |
| `apk.permissions.get` | Permission report |
| `state.get_all` | Device state snapshot |
| `apk.hello` / `apk.app_added` / `apk.app_removed` / `apk.app_count` | Handshake + live app-catalog events |
| `battery_small` / `battery_update` | Battery ticks |
| `volume_update` | Volume streams |

## Module map (this host)

```
lib/app.dart                 root: paths, dev log, settings bootstrap
├─ core/android_core.dart    central state store (ChangeNotifier)
│   ├─ settings              SettingsStore (wallpaper, last device, keys)
│   ├─ media                 MediaDataManager (3701 mirror)
│   ├─ notifications         NotificationDataManager (3700 mirror)
│   ├─ windows               WindowManager (z-order, snap, minimize)
│   └─ reconnection          ReconnectionManager (watchdog)
├─ services/boot_service.dart  host servers + boot sequence + ADB
├─ services/device_manager.dart  USB/Wi-Fi target resolution
├─ home/desktop_screen.dart   DeX shell: wallpaper/launcher/taskbar/panels
└─ home/embedded_app_window.dart  per-app scrcpy surface embed
```

### Error contract

Failures are two-tier: raw process output only ever reaches `DevLog`
(`%LOCALAPPDATA%\AndroidDEX\dev.log`); the UI gets plain-English
`AndroidDexError.userMessage`. `ConnectionFailure` subclasses additionally reveal
the "Open ADB Manager" recovery button on the boot screen. Reinstall-class
failures (missing bundle/APK/JAR, `isReinstallError`) never offer the picker —
they cannot be fixed from the device side.

### Game-mode coordinates

`GameProfile` button coordinates are stored in the Android **virtual display
space** (landscape, e.g. 1280x720 @ 240dpi — the display scrcpy opens). The
overlay maps them onto its own local pixel space and clamps to bounds, so
tapping the rendered control always injects the right device-side point.
Profiles are not interchangeable across different virtual-display sizes.

### Reconnection

After boot the `ReconnectionManager` watches `jarConnected` / `apkConnected`.
On drop it runs Phase 1 (re-apply the port bridge) then up to two Phase 2
(deploy JAR + relaunch APK service) attempts before surfacing a failed overlay.

## CLI / device targeting

```
androiddex_host.exe --usb          # pin the attached USB device
androiddex_host.exe 192.168.1.5    # Wi-Fi ADB (:5555 appended)
androiddex_host.exe                # auto-detect (pick if ambiguous)
```

Zero devices or several attached devices open the ADB Manager dialog before
boot; the same dialog is offered from the boot screen on a connection error.