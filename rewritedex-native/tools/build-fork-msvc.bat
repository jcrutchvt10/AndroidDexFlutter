@echo off
setlocal

REM ---------------------------------------------------------------------------
REM Build the RewriteDEX scrcpy fork on Windows using meson + MSVC.
REM
REM V3 changes vs V2:
REM   * Dropped vswhere.exe discovery (parens in %ProgramFiles(x86)% break CMD's
REM     in-file env var expansion, causing "vswhere. was unexpected at this
REM     time" errors). Replaced with a top-level flat for-loop over candidate
REM     vcvars64.bat paths — no nested parens, no quoted command subshell.
REM   * Added `-Db_vscrt=md` to meson setup so scrcpy.exe links against the
REM     dynamic MSVCRT (/MD) matching vcpkg's shared ffmpeg build (avoiding
REM     LIBCMT/MSVCRT defaultlib-mismatch warnings + LNK4098 at link time).
REM
REM V2->V3 retained fixes:
REM   * Sets PKG_CONFIG=<pkgconf.exe> env var (meson 1.11 has no
REM     --pkg-config-program flag at setup time).
REM   * Passes --pkg-config-path to meson for vcpkg .pc lookup dirs.
REM   * Wipes build dir with rmdir /s /q before each run so meson re-discovers
REM     rc.exe + libav* deps with the freshly-sourced SDK environment.
REM ---------------------------------------------------------------------------

REM --- vcvars64.bat discovery (flat top-level for-loop, no nesting) ---------
set "VCVARS="
for %%P in (
    "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
) do (
    if not defined VCVARS if exist %%P set "VCVARS=%%~P"
)

if not defined VCVARS (
    echo [build-fork-msvc] ERROR: could not locate vcvars64.bat.
    echo   VS 18/2022 x {Professional, Enterprise, Community, BuildTools} x {x64, x86 PFiles}.
    echo   Install a Visual Studio Build Tools / Community / Pro SKU with the Desktop dev C++ workload.
    exit /b 1
)

echo [build-fork-msvc] Sourcing vcvars64.bat from:
echo     %VCVARS%
call "%VCVARS%" >nul
if errorlevel 1 (
    echo [build-fork-msvc] ERROR: vcvars64.bat failed.
    exit /b 1
)

set "REPO_ROOT=%~dp0.."
pushd "%REPO_ROOT%"

REM --- pkg-config (vcpkg pkgconf) -------------------------------------------
set "PKGCONF_BIN=C:\vcpkg\installed\x64-windows\tools\pkgconf\pkgconf.exe"
set "PKG_CONFIG=%PKGCONF_BIN%"
set "PKGCFG_DIR=C:\vcpkg\installed\x64-windows\lib\pkgconfig"

if not exist "%PKGCONF_BIN%" (
    echo [build-fork-msvc] ERROR: pkgconf not found at %PKGCONF_BIN%.
    echo   Install with:  vcpkg install pkgconf:x64-windows
    popd
    exit /b 1
)

REM --- meson + ninja --------------------------------------------------------
set "BUILD_DIR=C:\build\meson-fork-msvc"
set "FORK_DIR=%REPO_ROOT%\third_party\scrcpy-fork\app"

if exist "%BUILD_DIR%" (
    echo [build-fork-msvc] Wiping existing build dir %BUILD_DIR%
    rmdir /s /q "%BUILD_DIR%"
)

echo [build-fork-msvc] meson setup --buildtype=release -Dc_std=c11 -Db_vscrt=md ...
echo     PKG_CONFIG    = %PKG_CONFIG%
echo     pkg-config-dir= %PKGCFG_DIR%
echo     build dir     = %BUILD_DIR%
echo     source dir    = %FORK_DIR%
meson setup --buildtype=release -Dc_std=c11 -Db_vscrt=md --pkg-config-path="%PKGCFG_DIR%" "%BUILD_DIR%" "%FORK_DIR%"
if errorlevel 1 (
    echo [build-fork-msvc] ERROR: meson setup failed.
    popd
    exit /b 1
)

echo [build-fork-msvc] ninja -C "%BUILD_DIR%" ...
ninja -C "%BUILD_DIR%"
if errorlevel 1 (
    echo [build-fork-msvc] ERROR: ninja failed.
    popd
    exit /b 1
)

echo.
echo [build-fork-msvc] SUCCESS.
if exist "%BUILD_DIR%\scrcpy.exe" (
    echo     Binary: %BUILD_DIR%\scrcpy.exe
    "%BUILD_DIR%\scrcpy.exe" --version
) else (
    echo     WARN: scrcpy.exe not produced (expected at %BUILD_DIR%\scrcpy.exe).
)
echo.
echo [build-fork-msvc] --viewports flag check:
"%BUILD_DIR%\scrcpy.exe" --help 2>&1 | findstr /C:"viewports" || echo     (not found in --help output - fork plumbing stage pending)

popd
endlocal
