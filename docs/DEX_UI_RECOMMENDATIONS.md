# RewriteDEX — UI-Friendliness & Samsung DeX Parity Recommendations

Review of the full codebase (native-controller, android-agent, scrcpy-fork,
build/packaging scripts) with a focus on making the product more *UI friendly*
and *more like Samsung DeX*.

---

## 1. Executive summary

RewriteDEX is architecturally strong in its transport layer: the scrcpy fork
delivers a decorated Android desktop at a stable ~700dp short side, the
`TaskOrganizer` broker already provides native per-task surfaces, and the agent
API is small, validated, and versioned. What is missing for DeX parity is almost
entirely on the **host side**: there is no visual shell.

The README states this is intentional — *"There is no Qt shell and no host
taskbar painted over Android."* That design decision is the root cause of the
gap. Samsung DeX is not a stream; it is a **window manager experience**: a
taskbar dock, an icon launcher with search, per-app windows with real
z-order, a notification center, and a settings panel. RewriteDEX today offers
all of that functionality, but only as **deeply nested tray context menus and
two small Win32 dialogs** (`main.cpp:2024-2415`).

The recommendations below fall into two buckets:

1. **Introduce a host-side visual shell** (dock, launcher, notification
   center, settings, workspace switcher) as a companion UI process, while
   preserving the core principle that Android owns all *rendering*.
2. **Consolidate the windowing model** on the existing `TaskOrganizer`
   compositor so every app is a real, independently-managed desktop window —
   the single biggest step toward feeling like DeX — and **retire the fragile
   shared-display + `am task resize` + logcat-polling path** that is currently
   the default (`DexAgentService.kt:717-781`, `982-1028`).

---

## 2. Current architecture (as reviewed)

| Layer | Component | Location | Notes |
|---|---|---|---|
| Host controller | Qt-free Win32 tray + control window | `native-controller/main.cpp` (2482 lines) | All UI, transport, settings, telemetry in one TU |
| Host state | `HostWorkspaceState` | `host_workspace_state.{h,cpp}` | pinned/recent apps, selected workspace (JSON) |
| Host settings | `rewritedex.ini` via `GetPrivateProfileIntW` | `main.cpp:211-224` | INI beside the exe |
| Agent | `DexAgentService.kt` (2157 lines) | Android HTTP server on `127.0.0.1:8792` | Root shell + `am` commands for everything |
| Agent UI | Settings / trackpad / widgets / export | `SettingsActivity.java`, `DesktopControlActivity.kt`, `DesktopWidgetActivity.kt`, `ExportToWindowsActivity.kt` | Small programmatic activities |
| Transport | scrcpy 4.1 fork | `third_party/scrcpy-fork` | `--desktop-transport`, UHID input, trailing-edge resize debounce |
| Window manager | Experimental `TaskOrganizer` broker | `scrcpy-fork/server/.../compositor/*` | Per-task mirror + encoder + HWND; opt-in ("Open native surface") |

### Key observations

- **UI is text-menu-based.** Running apps, workspaces, notifications, the app
  launcher, monitor selection, stream quality — every one is a `TrackPopupMenu`
  item (`main.cpp:1421-1638`, `1955-2022`). There are no icons, no search, no
  previews, no visual hierarchy.
- **Two parallel windowing systems.** The default path draws all freeform apps
  onto *one* shared virtual display and manipulates them with `am task resize`
  / `am task focus` root commands; the broker path gives each task its own
  HWND. The broker is strictly better for DeX parity but is not the default.
- **Heavy reliance on polling + logcat heuristics.** The agent runs `su -c
  logcat` watchers (`DexAgentService.kt:717-781`), an 80ms launch-watcher
  poll with an 8s window (`2114-2115`), a 5s task cache TTL, and "mirror the
  app to the desktop after it spilled onto the phone" reconciliation
  (`mirrorDesktopLaunchWithoutStealingPhone`, `1035-1073`). This is fragile and
  is the source of most launch jank.
- **Settings are split-brain.** Quality profile exists in both the host INI
  dialog and the Android `SettingsActivity` (`settings_activity.xml`,
  `SettingsActivity.java`) with no single source of truth.
- **No icons in the host launcher.** `/api/v1/apps` returns `package`, `label`,
  `component` only (`DexAgentService.kt:369-389`). A text menu is all the host
  can render.
- **Notifications are balloon tips.** The bridge stores up to 24 entries and
  the host shows the newest as a tray balloon (`main.cpp:1652-1666`).
- **Streaming-quality and monitor changes kill the session.** `restartDesktop()`
  (`main.cpp:1921-1929`) closes and relaunches scrcpy to apply most settings —
  a disruptive full teardown that DeX never does.

---

## 3. Recommendations

### 3.1 Add a host-side visual shell as a separate UI process (P0, highest impact)

DeX's identity is the taskbar dock + launcher + panels. This project can deliver
that without breaking the "Android owns rendering" principle because a host
shell is just **window chrome around the existing transport window(s)** — it
does not paint anything onto the Android surface.

Concrete proposal:

- **New companion process** `rewritedex-shell` (recommend WebView2-based UI, or
  WinUI 3 if the team prefers native). The shell owns:
  - a **taskbar dock** pinned to the bottom/edge of the desktop window:
    launcher button, pinned apps, running apps, workspace strip, notification +
    settings + connection-status tray area;
  - an **app launcher** with icons and search;
  - a **notification center** panel;
  - a **settings** panel;
  - a **workspace switcher** with preview thumbnails.
- The existing controller process keeps doing what it does well (device
  management, transport spawn/reconnect, input hooks, agent IPC) and exposes a
  **local control API** (named pipe or localhost HTTP — the controller already
  has a working loopback HTTP client in `agentRequest`, `main.cpp:340-401`).
  The shell is a pure client.
- **Why a separate process:** today the controller's window proc and its
  `WM_TIMER` loop (`main.cpp:2072-2136`) handle transport *and* UI. A UI crash
  or a modal `MessageBoxW` (e.g. `showDiagnostics`, `1723-1739`) can stall the
  whole desktop. A separate shell means UI churn can never drop the stream.

This is the single change that moves the product from "scrcpy with tray menus"
to "DeX".

### 3.2 Make the TaskOrganizer compositor the default windowing path (P0)

The broker already produces exactly what DeX offers: a real task leash per app,
an independent surface, and a managed HWND. It is currently opt-in per task
("Open native surface (broker)", `main.cpp:1548-1554`). Recommend:

- Launch **every** app through the broker; the shared virtual-display transport
  remains only as the compatibility/fallback shell.
- Have the broker manage *all* tasks on the desktop display instead of only
  ones the user explicitly opens. Then:
  - the launch-watcher/logcat reconciliation code can be retired
    (`watchDesktopClickLaunches`, `redirectPhoneTaskFromDesktopClick`,
    `mirrorDesktopLaunchWithoutStealingPhone`);
  - window close/move/resize become broker operations instead of
    `am task resize` + polling;
  - the host shell's taskbar can enumerate windows from the broker's task list
    and get live z-order, focus, and bounds — the data DeX's taskbar shows.
- The host already has most of the management code (`main.cpp:899-1111`); the
  work is making it the default and wiring the shell to it.

### 3.3 Ship app icons to the host (P1 — unblocks a real launcher)

Without icons there is no launcher. Add:

- Agent endpoint `GET /api/v1/app-icons/{package}` that renders the app's
  launcher icon (via `PackageManager` / `IconCompat.loadDrawable`) to a PNG
  (rounded, themed), or batches them in `/api/v1/apps`.
- Host-side icon cache (`%LOCALAPPDATA%\RewriteDEX\icons\{pkg}.png`) populated
  from the agent, similar to how `host-workspace.json` is managed
  (`main.cpp:2446-2448`).
- The shell renders pinned/recent/all-app grids from the existing
  `appendWindowsLauncherMenu` data (`main.cpp:1421-1470`) plus icons, with a
  text search field.

This is pure transport work + one endpoint; it is the cheapest DeX-visual win.

### 3.4 Replace balloons with a notification center panel (P1)

Today: opt-in bridge → up to 24 stored entries → newest shown as tray balloon
(`main.cpp:1652-1666`); the phone's own shade is deliberately blocked
(`DexAgentService.kt:1361-1363`).

Recommend a host-side notification center fed by `/notifications`:
- group by package, show timestamp + click-to-open (already possible via the
  stored `package`), per-group clear and clear-all (`/notifications/clear`);
- enrich `DesktopNotificationListenerService.kt` to capture action intents
  (`Notification.extras`), priority, and, optionally, large-icon/thumbnail so
  the panel looks like DeX's, not a chat log;
- surface it from the shell dock, not the tray menu.

### 3.5 Make workspaces a visible, keyboard-driven surface (P1)

Workspaces are today a nested menu (`appendWorkspacesMenu`, `main.cpp:1594-1613`)
and a host workspace switcher menu (`1472-1490`). DeX-style:

- Add a workspace strip to the dock (Desktop / Work / Media / Personal…) with a
  **live preview thumbnail** per workspace. Previews can be captured from the
  already-running scrcpy frame or a broker surface screenshot (there is already
  a screenshot path in `captureScreenshot`, `main.cpp:1931-1953`).
- Map `Win+1..9` / `Ctrl+Alt+1..9` to workspace selection (the shortcut
  infrastructure already exists at `keyboardHookProc`, `main.cpp:528-577`).

### 3.6 Unify settings into one host surface (P1)

Kill the split-brain:
- Host `rewritedex.ini` (`main.cpp:211-224`) and agent `SettingsActivity`
  preferences both control overlapping knobs (quality profile appears in both).
- Move all user settings to the host shell; expose agent-owned knobs (wallpaper
  interval/dim, profiles) through the existing API (`/wallpaper`,
  `/profiles`) so the shell is the only settings UI.
- Introduce one typed settings schema (single struct + JSON, replacing the
  INI `GetPrivateProfileIntW` calls) so validation and defaults live in one
  place.

### 3.7 Stop restarting the stream to apply settings (P1 — UX quality)

`restartDesktop()` (`main.cpp:1921-1929`) tears down and respawns scrcpy for
quality/monitor/audio/recording changes. Users see the desktop vanish for
seconds. Two options:

- Add **in-place reconfiguration** to the fork: `server/.../Options` and the
  encoder (`SurfaceEncoder.java`) can be told to change bitrate/fps on the fly;
  the controller sends a control message instead of killing the process.
- At minimum, pre-warm the new process before closing the old one (double
  buffer the transport) so the switch is seamless.

### 3.8 Decompose the monoliths (P2 — maintainability that enables the above)

- `native-controller/main.cpp` (2482 lines) mixes transport, input hooks,
  UI, settings, telemetry, and the agent HTTP client. Split into translation
  units: `transport.{h,cpp}`, `agent_client.{h,cpp}`, `input_hooks.{h,cpp}`,
  `settings.{h,cpp}`, `tray_ui.{h,cpp}`, `shell_ipc.{h,cpp}`. The shell work in
  §3.1 requires this anyway (the shell talks to a stable control API, not to a
  2400-line switch statement).
- `DexAgentService.kt` (2157 lines) mixes HTTP routing, root-shell execution,
  task management, workspace persistence, wallpaper, notifications, and input
  handling. Split into `AgentHttpServer.kt`, `RootShell.kt`, `TaskController.kt`,
  `DesktopLauncher.kt`, `WorkspaceManager.kt`.
- Move UI strings into resource/string tables on both sides (all tray labels
  and messages are hardcoded today), which also enables localization.

### 3.9 Keyboard shortcuts: customizable + discoverable (P2)

- Current model is three hardcoded presets (Windows key vs Ctrl+Alt vs off)
  and a fixed chord→command map in `keyboardHookProc` (`main.cpp:528-577`).
- Make the map data-driven (JSON) and editable in the settings panel; add
  conflict detection.
- Add a DeX-style **shortcut help overlay** (`Win+/` or a dock button) rendered
  by the shell listing active chords — discoverability is a big part of feeling
  "like a desktop".

### 3.10 First-run experience / onboarding (P2)

- The only onboarding today is the status line "Looking for a connected Pixel…"
  (`main.cpp:97`). A first-run wizard in the shell would walk users through:
  enable USB debugging → authorize ADB → install agent → grant root →
  enable notification access (a DeX-first feel).
- The agent already exposes everything needed (`/status` returns root,
  taskTracking, notificationAccess; `main.cpp:1723-1739`).

### 3.11 Consistent visual language & DPI (P2)

- Colors are hand-rolled on both sides: host `RGB(18,20,22)` / accent
  `RGB(138,180,248)` in `WM_PAINT` (`main.cpp:2328-2391`); agent `#121212` /
  `#8ab4f8` in `styles.xml`. Centralize into a small design-token header /
  resource file shared conceptually by host shell and agent so light/dark and
  accent theming are consistent with the Android desktop.
- The control window and settings dialog are fixed-size (`main.cpp:2459-2460`,
  `1908-1909`); make them resizable/DPI-scalable.

---

## 4. What not to change (guardrails)

- **Keep Android as the renderer.** Do not paint host-side decorations/taskbars
  *onto* the Android surface, and do not reintroduce overlay windows on the
  virtual display (the agent correctly avoided `SYSTEM_ALERT_WINDOW` because
  SystemUI force-hides non-system overlays — see `DesktopWidgetActivity.kt:27-34`).
  The shell in §3.1 is host window chrome *around* the transport, which is
  safe and unifies the model.
- **Do not increase reliance on `am`/root polling.** The direction should be
  *away* from logcat heuristics and toward broker-owned tasks (§3.2). New UI
  work must not add more `su -c` polling.
- **Keep the agent API surface small and validated.** New endpoints
  (icons, notification actions) should follow the existing pattern: metadata
  only, validated inputs, token-gated (`main.cpp:368`, `DexAgentService.kt:337-362`).

---

## 5. Prioritized roadmap

| Priority | Item | Effort | Why |
|---|---|---|---|
| P0 | Host visual shell process (dock/launcher/panels) | Large | This *is* the DeX difference |
| P0 | Broker path becomes default windowing | Large | Real per-app windows; removes polling fragility |
| P1 | App-icon transport + host cache | Small | Unblocks a real launcher |
| P1 | Notification center panel | Small-Med | DeX notification UX |
| P1 | Workspace strip with previews + hotkeys | Med | Multi-desktop feel |
| P1 | Unified host settings (single schema) | Med | One place to configure |
| P1 | In-place stream reconfiguration (no restart) | Med | Removes disruptive teardowns |
| P2 | Decompose monoliths, string resources | Med | Enables everything above |
| P2 | Data-driven shortcut map + help overlay | Small | Discoverability |
| P2 | First-run wizard | Small-Med | Onboarding quality |
| P2 | Design tokens + DPI-scalable dialogs | Small | Visual consistency |

The fastest path to a *demonstrable* DeX feel is §3.3 (icons) + §3.4
(notification panel) + §3.1-lite (a dock) on top of the existing transport;
the most *architecturally* correct path to long-term parity is §3.2 (make the
compositor the default) followed by the full shell.
