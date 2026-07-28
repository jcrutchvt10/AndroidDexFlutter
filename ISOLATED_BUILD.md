# FinalPixelDexNative

This folder is a self-contained snapshot of the active Pixel-native RewriteDEX
implementation copied from `C:\Users\jason\rewritedex` on July 28, 2026.

## Included

- The Win32 controller and tray application source.
- The rooted Android agent and framework-overlay source.
- The persistent TaskOrganizer compositor broker and hidden API stubs.
- The modified scrcpy client and server source.
- A portable scrcpy/ADB runtime with the latest built fork and server.
- The latest built controller, Android agent APK, and framework-overlay APK.
- Build, launch, packaging, verification, and wallpaper scripts.
- Project documentation, license, and CI metadata.

## Deliberately excluded

- Git metadata and editor/agent configuration.
- The local `.env` file and all real credentials.
- Machine-specific Android `local.properties` (Gradle will regenerate it).
- Rooted-device session tokens, ADB dumps, recordings, and runtime state.
- Screenshots, logs, symbol files, object files, and compiler caches.
- Old release archives and the separate ChromeDEX prototype.

## Layout

```text
FinalPixelDexNative/
|-- launch.ps1
|-- build.ps1
|-- rewritedex-native/
|   |-- native-controller/
|   |-- android-agent/
|   |-- tools/
|   `-- build/rewritedex-native.exe
`-- third_party/
    |-- scrcpy-fork/
    `-- scrcpy/
```

The directory layout is intentional. The controller and build scripts resolve
the scrcpy source and runtime through repository-relative paths.

## Run

Connect the rooted Pixel with USB debugging enabled, then:

```powershell
Set-Location C:\Users\jason\FinalPixelDexNative
.\launch.ps1
```

If local-only environment settings are needed, copy `.env.example` to `.env`
and fill it in. Never put credentials into the Android agent or source files.

## Build and verify

Requirements are listed in `README.md`. From this folder:

```powershell
.\build.ps1
.\verify.ps1 -SkipDevice
```

The full PowerShell build uses
`%TEMP%\build-scrcpy-fork-final-pixel-dex-native` as an optional existing
scrcpy client cache unless `SCRCPY_BUILD_DIR` is set. This package-specific
default prevents an older checkout's Meson cache from being used accidentally.
If the cache is absent, the bundled client remains usable and the controller,
Android components, and scrcpy server still build from this isolated tree.

To rebuild the client from this copy with MSYS2 UCRT64, run the relocatable
`rewritedex-native\tools\build-fork-msys2-ucrt.sh` helper in an MSYS2 UCRT64
shell.

Install the freshly built agent without clearing its data:

```powershell
adb install -r .\rewritedex-native\android-agent\app\build\outputs\apk\debug\app-debug.apk
```
