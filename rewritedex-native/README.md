# RewriteDEX Native

RewriteDEX Native presents Android apps from a connected Pixel on Windows over
USB. The Pixel remains the Android runtime and renders app surfaces, while
Windows owns the command surface: app discovery/launch, pinned and recent apps,
workspace selection, transport settings, diagnostics, and host notifications.
Launcher3 remains available as a compatibility fallback, not the normal way to
start an app from the desktop.

The project has three deliberately small pieces:

- `native-controller`: a Qt-free Win32 launcher and tray controller
- `android-agent`: a local, root-aware task and session bridge on the Pixel
- `third_party/scrcpy-fork`: the display, input, audio, clipboard, and file
  transport

## Requirements

- Pixel with Android desktop experience enabled in Developer options
- USB debugging and an authorized ADB connection
- Root for task focus, resize, close, and reliable display-targeted launches
- Windows 10 or newer
- CMake, Ninja, Android SDK 36, JDK, MSYS2 UCRT64, and the existing scrcpy
  Meson build tree when rebuilding every component

## Build

From this directory:

```powershell
.\build.ps1
```

The build produces:

- `build\rewritedex-native.exe`
- `android-agent\app\build\outputs\apk\debug\app-debug.apk`
- `..\third_party\scrcpy\scrcpy-fork.exe`
- `..\third_party\scrcpy\scrcpy-server`

Install the agent once with:

```powershell
adb install -r android-agent\app\build\outputs\apk\debug\app-debug.apk
```

Then from the repo root run `..\launch.ps1`, use the Desktop **RewriteDEX**
shortcut, or double-click `build\rewritedex-native.exe --start`. The controller
starts the agent, creates the reverse ADB tunnel, and opens the Pixel desktop.
Scrcpy is spawned with `CREATE_NO_WINDOW` (no black console).

## Desktop Transport

The controller launches the fork with `--new-display=WxH/dpi` and
`--desktop-transport`. The latter is the RewriteDEX alias for `--flex-display`.
It also pins `SCRCPY_SERVER_PATH` to the server beside the fork executable, so
an installed stock or older scrcpy server cannot shadow the RewriteDEX build.
The initial density targets a 700dp short side. During a Windows resize, scrcpy
scales the current frame immediately and commits a new Android display size
after a 300ms trailing-edge debounce. Density changes with the pixel size so
the Android desktop's logical short side stays stable.

Input is sent through scrcpy, including Android Alt+Tab and Alt+F4 while the
desktop window is focused. Clipboard synchronization, device audio, and native
scrcpy file drop to `/sdcard/Download/` are enabled. The controller itself
retires to the Windows notification area after the desktop opens.

The Windows workspace command center manages Android tasks and named workspaces, stream
quality, desktop audio streaming toggle, configurable shell shortcuts, screenshots and recording, notification
mirroring, bidirectional file exchange, physical-display preference, and one
Android desktop per Windows monitor. Settings (including the new audio toggle) persist in `rewritedex.ini`
beside the controller. `Android apps` opens a native Windows launcher sourced
from the agent; its pins, recent launches, and selected workspace persist in
`%LOCALAPPDATA%\RewriteDEX\host-workspace.json`, independently of the phone.
The tray also offers quick launch of the agent Settings activity on the Pixel.
Unexpected transport exits reconnect automatically.

## Experimental Task Compositor

The rooted privileged compositor is available from **Running apps**: choose an
Android task, then **Open native surface (broker)**. RewriteDEX starts one
persistent root broker for the desktop session. That process registers a
single Android `TaskOrganizer`, retains each task leash, and gives every opened
task its own `SurfaceControl.mirrorSurface()` hierarchy, encoder, USB stream,
and managed Windows window:

`TaskOrganizer leash -> SurfaceControl mirror -> MediaCodec -> USB -> managed HWND`

Several task surfaces may run concurrently through the same broker. Opening a
task that already has a Windows surface focuses the existing HWND; each surface
can also be closed independently. The broker stays alive until RewriteDEX
quits, and task resize/display changes reset only the affected encoder.

These are task-only streams, not crops of the shared Android display. Mouse
coordinates are translated back into each task's live bounds and injected on
its source display. Broker-owned private displays are excluded from desktop
display discovery so they cannot replace the primary desktop transport.

With the broker already started by RewriteDEX, the scrcpy fork also exposes a
diagnostic form. Point it at RewriteDEX's server build so a globally installed
scrcpy server is not selected:

```powershell
$env:SCRCPY_SERVER_PATH = Resolve-Path ..\third_party\scrcpy\scrcpy-server
..\third_party\scrcpy\scrcpy-fork.exe -s <serial> `
  --task-id=<taskId> --display-id=<sourceDisplayId> --no-audio --no-cleanup
```

The current implementation requires a rooted device because `TaskOrganizer`
and the task leashes are privileged platform APIs. It has been exercised on
the rooted Pixel 9 Pro XL running Android 17. The shared desktop transport
remains the compatibility fallback.

## Device Agent

The agent listens only on `127.0.0.1:8792`, exposed to the host with
`adb forward`. Its endpoints cover status, real Android tasks, display-targeted
app launch, focus/minimize/close/resize actions, system panels, and session
bounds, workspaces, notification history, and device-to-PC exports. Package
names, filenames, workspace names, and task actions are validated before root
commands are executed.

The versioned host-shell contract is deliberately small:

- `GET /api/v1/apps` returns launchable, non-system Android apps for the Windows launcher.
- `GET /api/v1/events?cursor=<n>` is a bounded long-poll feed for display, task,
  app-launch, and notification changes. The controller uses it to reconcile
  transport display topology without blocking its UI thread.

Both endpoints require the same per-session `X-RewriteDEX-Token` as the legacy
control API and expose metadata only; privileged task operations remain behind
the existing validated command endpoints.

## Pixel Customization Policy

No visual resource overlay is installed. The Android 17 SystemUI and Pixel
Launcher builds on the attached Pixel expose no public overlayable groups for
the desktop taskbar or desktop window decorations. Modifying private resources
would be update-fragile and could break SystemUI. Native Pixel visuals are kept
intact until Google exposes a supported overlay or shell customization surface.
