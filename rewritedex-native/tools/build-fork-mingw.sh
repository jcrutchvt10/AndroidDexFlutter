#!/bin/bash
# ---------------------------------------------------------------------------
# Build the RewriteDEX scrcpy fork as a Windows .exe via cross-compile.
#
# Run from WSL2 bash (NOT from MSYS bash on Windows):
#   wsl --exec bash /mnt/c/Users/<user>/FinalPixelDexNative/rewritedex-native/tools/build-fork-mingw.sh
#
# Uses:
#   * Toolchain: x86_64-w64-mingw32-gcc + x86_64-w64-mingw32-pkg-config
#   * Meson cross-file: rewritedex-native/tools/wsl-mingw-cross.ini
#   * Static linking -static -static-libgcc → self-contained .exe that depends
#     only on system-provided msvcrt.dll (no libgcc_s_seh-1.dll etc.)
#
# Output:
#   /tmp/build-scrcpy-mingw/scrcpy.exe
#
# After a successful build, the command printed at the end deploys the binary
# into this checkout's bundled scrcpy runtime.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_WSL="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Sanity: confirm we're running in WSL2 Linux (not Git Bash / MSYS bash on Windows)
if ! grep -qE '(Microsoft|WSL)' /proc/version 2>/dev/null; then
    echo "[build-fork-mingw] ERROR: must run from WSL2 bash, not MSYS/Git Bash."
    echo "    From Windows:  wsl --exec bash <package>/rewritedex-native/tools/build-fork-mingw.sh"
    exit 1
fi
cd "$REPO_ROOT_WSL"

# Sanity: toolchain installed
command -v x86_64-w64-mingw32-gcc      >/dev/null || { echo "ERROR: gcc-mingw-w64-x86-64 not installed"; exit 1; }
command -v x86_64-w64-mingw32-pkg-config >/dev/null || { echo "ERROR: mingw pkg-config not installed"; exit 1; }
command -v meson                       >/dev/null || { echo "ERROR: meson not installed"; exit 1; }
command -v ninja                       >/dev/null || { echo "ERROR: ninja not installed"; exit 1; }

BUILD_DIR="/tmp/build-scrcpy-mingw"
FORK_DIR="$REPO_ROOT_WSL/third_party/scrcpy-fork/app"
CROSS_FILE="$SCRIPT_DIR/wsl-mingw-cross.ini"

if [ ! -f "$CROSS_FILE" ]; then
    echo "ERROR: cross-file missing: $CROSS_FILE"
    exit 1
fi

echo "[build-fork-mingw] Cleaning previous build dir $BUILD_DIR ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[build-fork-mingw] meson setup --cross-file $CROSS_FILE ..."
echo "    cross-file   = $CROSS_FILE"
echo "    fork source  = $FORK_DIR"
echo "    build dir    = $BUILD_DIR"
meson setup "$BUILD_DIR" \
    --cross-file "$CROSS_FILE" \
    --buildtype release \
    -Dstatic=true \
    -Dc_link_args="-static -static-libgcc" \
    "$FORK_DIR" 2>&1 | tail -30

echo "[build-fork-mingw] ninja -C $BUILD_DIR ..."
ninja -C "$BUILD_DIR" 2>&1 | tail -25

EXE="$BUILD_DIR/scrcpy.exe"
if [ ! -f "$EXE" ]; then
    echo "[build-fork-mingw] ERROR: scrcpy.exe not produced (expected at $EXE)."
    exit 1
fi

echo ""
echo "[build-fork-mingw] ============= SUCCESS ============="
echo "    Binary: $EXE ($(du -h "$EXE" | cut -f1))"
echo "    --version:"
"$EXE" --version
echo ""
echo "    --viewports flag check:"
if "$EXE" --help 2>&1 | grep -B 1 -A 3 -i 'viewports' ; then
    :
else
    echo "    (no --viewports in --help output — fork plumbing stage pending)"
fi
echo ""
echo "[build-fork-mingw] To deploy, copy to the host bundled-scrcpy dir:"
echo "    cp '$EXE' '$REPO_ROOT_WSL/third_party/scrcpy/scrcpy.exe'"
