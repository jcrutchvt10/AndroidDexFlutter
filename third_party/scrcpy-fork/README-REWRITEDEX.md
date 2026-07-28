# RewriteDEX scrcpy Fork

This is a downstream fork of [scrcpy](https://github.com/Genymobile/scrcpy) tailored for RewriteDES native desktop transport. The upstream base is **scrcpy 4.1** (exact client/server match required at runtime).

## RewriteDEX-specific changes

### Tier 1 — Desktop transport
- `--desktop-transport` CLI alias for `--flex-display`
  Files: `app/src/cli.c`, `app/src/scrcpy.c`, `app/src/screen.c`
- `--display-ime-policy=local` keeps the IME on the Android virtual display rather than the phone display
  Files: `app/src/cli.c`, `server/...`
- `--no-vd-destroy-content` preserves Android tasks when the virtual display is torn down
  Files: `app/src/cli.c`, `server/...`

### Tier 2 — Resize & DPI
- Trailing-edge 300 ms debounce on Windows window resize; commits even pixel dimensions only
  Files: `app/src/screen.c`, `app/src/util/sdl.c`
- WM base-density preservation so Android logical short side stays near 700 dp
  Files: `app/src/screen.c`
- Per-Monitor V2 DPI awareness in `scrcpy.exe` (Windows manifest + SDL hints)
  Files: `app/src/main.c`, `app/scrcpy-windows.manifest`

### Tier 3 — Input & integration
- `keyboard=uhid`, `mouse=uhid` (freeform drag/resize), `gamepad=uhid`, `shortcut-mod=lsuper` for desktop use
  Files: `app/src/cli.c`
- Forwarded Alt+Tab / Alt+F4 when the scrcpy desktop window is focused (handled by RewriteDEX controller, not scrcpy)
  Files: `app/src/input_manager.c` (pass-through path preserved)

### Tier 4 — Multi-viewport groundwork
- `--viewports` CLI option stub for future multi-monitor extensions
  Files: `app/src/cli.c`

## Rebuilding

Use the MSYS2 UCRT64 toolchain on Windows:

```bash
# Cross-compilation from WSL2 or native MSYS2
bash tools/build-fork-mingw.sh
```

Or use the existing Meson build tree:

```powershell
cd third_party/scrcpy-fork
meson setup c:/tmp/build-scrcpy-fork --cross-file wsl-mingw-cross.ini
ninja -C c:/tmp/build-scrcpy-fork
```

## Pinning the server version

The `BuildConfig.VERSION_NAME` in the Java server **must** match the C client `SCRCPY_VERSION` exactly or the server aborts on connection. `build-scrcpy-server.ps1` stamps `4.1`; when rebasing on a newer upstream, update both:

- `app/src/version.c` (`SCRCPY_VERSION`)
- `tools/build-scrcpy-server.ps1` (`BuildConfig.VERSION_NAME`)
- This README.
