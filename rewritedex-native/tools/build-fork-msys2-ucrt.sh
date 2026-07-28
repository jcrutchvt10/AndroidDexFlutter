#!/bin/bash
# ---------------------------------------------------------------------------
# Build the RewriteDEX scrcpy fork INSIDE MSYS2 UCRT64 native shell.
#
# Run via wrapper:
#   scripts\build-fork-msys2-ucrt.bat  (Windows side)
#
# What it does:
#   1. Installs (if missing) the UCRT64-aligned mingw-w64 toolchain +
#      ffmpeg + sdl3 via pacman.
#   2. meson setup a fresh build dir against the fork source (no --cross-file,
#      because we're building natively in MSYS2).
#   3. ninja produces a UCRT-MinGW scrcpy.exe with the fork's --viewports flag.
#   4. Bundles MinGW DLLs alongside the binary (detected via objdump).
#   5. Copies binary + DLLs to third_party/scrcpy/scrcpy.exe.
#   6. Verifies --version + --viewports flag in --help.
#
# Why shared linking (-Dstatic=false)?
#   Full static linking proved infeasible because several transitive
#   dependencies (libhwy.a for jxl, etc.) don't ship as static .a files
#   in MSYS2 UCRT64. The pragmatic solution: build shared and bundle
#   the MinGW DLLs, ensuring all runtime deps are self-consistent.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_WSL="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "${MSYSTEM:-}" != "UCRT64" ]; then
    echo "[build-fork-msys2-ucrt] ERROR: must be in MSYS2 UCRT64 shell (MSYSTEM=$MSYSTEM)."
    echo "  Launch via: C:\\msys64\\ucrt64.exe OR scripts\\build-fork-msys2-ucrt.bat"
    exit 1
fi

cd "$REPO_ROOT_WSL" || { echo "ERROR: cannot cd to $REPO_ROOT_WSL"; exit 1; }

# --- install UCRT64 toolchain + ffmpeg + sdl3 ------------------------------
echo "[build-fork-msys2-ucrt] Installing UCRT64 mingw + ffmpeg + sdl3 (idempotent pacman -S --needed)..."
pacman -S --needed --noconfirm \
    mingw-w64-ucrt-x86_64-gcc \
    mingw-w64-ucrt-x86_64-ffmpeg \
    mingw-w64-ucrt-x86_64-sdl3 \
    mingw-w64-ucrt-x86_64-pkgconf \
    mingw-w64-ucrt-x86_64-meson \
    mingw-w64-ucrt-x86_64-dlfcn \
    mingw-w64-ucrt-x86_64-ninja 2>&1 | tail -8 || true

# --- define UCRT64 sysroot + force pkg-config to look there ---------------
UCRT_BIN="/ucrt64/bin"
UCRT_LIB="/ucrt64/lib"
UCRT_PC="$UCRT_LIB/pkgconfig"
export PKG_CONFIG_PATH="$UCRT_PC:${PKG_CONFIG_PATH:-}"
export PATH="$UCRT_BIN:$PATH"
PKG_CONFIG_BIN="/ucrt64/bin/pkg-config.exe"
[ -x "$PKG_CONFIG_BIN" ] || PKG_CONFIG_BIN="$(command -v pkg-config)"
echo "[build-fork-msys2-ucrt] pkg-config: $PKG_CONFIG_BIN"

# --- verify deps are visible to pkg-config --------------------------------
echo "[build-fork-msys2-ucrt] Verifying dependencies..."
MISSING=()
for pkg in libavformat libavcodec libavutil libswresample sdl3; do
    if ! "$PKG_CONFIG_BIN" --exists "$pkg"; then
        MISSING+=("$pkg")
    else
        VER="$("$PKG_CONFIG_BIN" --modversion "$pkg")"
        echo "    $pkg: OK (v$VER)"
    fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "[build-fork-msys2-ucrt] ERROR: missing deps: ${MISSING[*]}"
    exit 1
fi

# --- meson + ninja build ---------------------------------------------------
BUILD_DIR="/tmp/build-scrcpy-fork"
FORK_DIR="$REPO_ROOT_WSL/third_party/scrcpy-fork/app"

export CFLAGS="-D__USE_MINGW_ANSI_STDIO=1 ${CFLAGS:-}"
export CXXFLAGS="-D__USE_MINGW_ANSI_STDIO=1 ${CXXFLAGS:-}"

echo "[build-fork-msys2-ucrt] Cleaning $BUILD_DIR..."
rm -rf "$BUILD_DIR"

echo "[build-fork-msys2-ucrt] meson setup --buildtype release ..."
(
    cd "$FORK_DIR" || { echo "    ERROR: cannot cd to $FORK_DIR"; exit 1; }
    [ -f meson.build ] || { echo "    ERROR: meson.build not found"; exit 1; }
    export MSYSTEM="UCRT64"
    export PKG_CONFIG_PATH="/ucrt64/lib/pkgconfig"
    export PATH="/ucrt64/bin:$PATH"
    meson setup "$BUILD_DIR" \
        -Dc_std=c11 \
        --buildtype release \
        -Dstatic=false 2>&1 | tee /tmp/meson_output.log
    exit "${PIPESTATUS[0]}"
)
MESON_EXIT=$?
if [ $MESON_EXIT -ne 0 ]; then
    echo "[build-fork-msys2-ucrt] ERROR: meson setup failed (exit=$MESON_EXIT)"
    tail -20 /tmp/meson_output.log 2>/dev/null || true
    exit 1
fi

echo "[build-fork-msys2-ucrt] ninja -C $BUILD_DIR ..."
ninja -C "$BUILD_DIR" 2>&1 | tee /tmp/ninja_output_fork.log
NINJA_EXIT=${PIPESTATUS[0]}

EXE="$BUILD_DIR/scrcpy.exe"
if [ ! -f "$EXE" ]; then
    echo "[build-fork-msys2-ucrt] ERROR: scrcpy.exe not produced at $EXE"
    ls -la "$BUILD_DIR/" 2>&1 | sed 's/^/    /'
    echo "    ninja exit code: $NINJA_EXIT"
    exit 1
fi

echo ""
echo "[build-fork-msys2-ucrt] ============= SUCCESS ============="
echo "    Binary: $EXE ($(du -h "$EXE" | cut -f1))"
echo "    --version:"
"$EXE" --version
echo "    --viewports flag check:"
if "$EXE" --help 2>&1 | grep -B 1 -A 3 -i 'viewports'; then
    :
else
    echo "    (no --viewports in --help output)"
fi

# --- bundle MinGW DLLs from /ucrt64/bin/ ----------------------------------
echo ""
echo "[build-fork-msys2-ucrt] Bundling MinGW DLLs from /ucrt64/bin/ ..."
# Detect DLL dependencies via objdump (skip system DLLs like KERNEL32, USER32)
NEEDED_DLLS=$(objdump -p "$EXE" 2>/dev/null | grep "DLL Name" | \
              awk '{print $3}' | grep -ivE '^(KERNEL32|USER32|GDI32|ADVAPI32|SHELL32|OLE32|OLEAUT32|COMDLG32|WINSPOOL|IMM32|WS2_32|MSCTF|SHLWAPI|UCRTBASE|VCRUNTIME|api-ms-win-crt)')
if [ -z "$NEEDED_DLLS" ]; then
    echo "    (objdump unavailable, using known DLL list)"
    NEEDED_DLLS="SDL3.dll avcodec-62.dll avformat-62.dll avutil-60.dll swresample-6.dll"
fi
for dll in $NEEDED_DLLS; do
    src="/ucrt64/bin/$dll"
    if [ -f "$src" ]; then
        cp -f "$src" "$BUILD_DIR/"
        echo "    bundled: $dll"
    fi
done
# Also bundle GCC runtime DLLs
for pattern in libgcc_s_seh*.dll libstdc++*.dll libssp*.dll libwinpthread*.dll; do
    for src in /ucrt64/bin/$pattern; do
        [ -f "$src" ] && cp -f "$src" "$BUILD_DIR/" && \
            echo "    bundled: $(basename $src)"
    done
done
echo "    DLL bundle complete."

# --- deploy ----------------------------------------------------------------
echo ""
echo "[build-fork-msys2-ucrt] Deploying to third_party/scrcpy/ ..."
cp -f "$EXE" "$REPO_ROOT_WSL/third_party/scrcpy/scrcpy.exe"
echo "    scrcpy.exe deployed ($(du -h "$REPO_ROOT_WSL/third_party/scrcpy/scrcpy.exe" | cut -f1))"
cp -f "$EXE" "$REPO_ROOT_WSL/third_party/scrcpy/scrcpy-fork.exe"
echo "    scrcpy-fork.exe deployed ($(du -h "$REPO_ROOT_WSL/third_party/scrcpy/scrcpy-fork.exe" | cut -f1))"

for dll in $NEEDED_DLLS; do
    src="/ucrt64/bin/$dll"
    if [ -f "$src" ]; then
        cp -f "$src" "$REPO_ROOT_WSL/third_party/scrcpy/"
        echo "    deployed: $dll"
    fi
done
for pattern in libgcc_s_seh*.dll libstdc++*.dll libssp*.dll libwinpthread*.dll; do
    for src in /ucrt64/bin/$pattern; do
        [ -f "$src" ] && cp -f "$src" "$REPO_ROOT_WSL/third_party/scrcpy/" && \
            echo "    deployed: $(basename $src)"
    done
done
echo "    DLL deployment complete."
echo ""
echo "[build-fork-msys2-ucrt] ============= ALL DONE ============="
