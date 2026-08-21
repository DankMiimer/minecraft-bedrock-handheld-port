#!/bin/bash
set -euo pipefail
ARCH="${1:?aarch64 or armhf}"
EDITION="${2:?standard or rgds}"
case "$ARCH:$EDITION" in
  aarch64:standard|aarch64:rgds|armhf:standard) ;;
  *) echo "unsupported client target: $ARCH/$EDITION" >&2; exit 2 ;;
esac

MANIFEST_COMMIT=368e38b2be8e0396693e9e56c9ec6402b933b426
WORK=/work/mcpelauncher
git clone --filter=blob:none https://github.com/minecraft-linux/mcpelauncher-manifest.git "$WORK"
git -C "$WORK" checkout --detach "$MANIFEST_COMMIT"
git -C "$WORK" submodule update --init --recursive

apply_component() {
  local component="$1" commit="$2" patch="$3"
  git -C "$WORK/$component" checkout --detach "$commit"
  git -C "$WORK/$component" apply --recount --check "/patches/$patch"
  git -C "$WORK/$component" apply --recount "/patches/$patch"
}
apply_component game-window 1777cab60232b20e47a36698d129faeb263ba357 game-window.patch
apply_component libc-shim e40f8feee463d852852ed442ea3db9a6320000b2 libc-shim.patch
apply_component linux-gamepad 68d75a74f80a93ec4ff7a96eea0909df28d45330 linux-gamepad.patch
apply_component mcpelauncher-client 4c5f4fdaad9888bb5b17722242ba4d6e8d8cb16d mcpelauncher-client.patch
git -C "$WORK/mcpelauncher-linker" apply --recount --check \
  /patches/mcpelauncher-linker-gcc.patch
git -C "$WORK/mcpelauncher-linker" apply --recount \
  /patches/mcpelauncher-linker-gcc.patch
# This exact four-line replacement sits between whitespace-only upstream lines,
# so keep it isolated and opt into zero-context matching only for this pinned
# commit. Every other source patch retains normal context validation.
git -C "$WORK/mcpelauncher-client" apply --recount --unidiff-zero --check \
  /patches/mcpelauncher-client-armhf-guard.patch
git -C "$WORK/mcpelauncher-client" apply --recount --unidiff-zero \
  /patches/mcpelauncher-client-armhf-guard.patch
if [ "$EDITION" = rgds ]; then
  python3 /telemetry/apply_client_patch.py "$WORK"
fi

case "$ARCH" in
  aarch64)
    TRIPLE=aarch64-linux-gnu; PROCESSOR=aarch64
    STRIP=aarch64-linux-gnu-strip; TARGET_FEATURES=
    GAMEWINDOW_SYSTEM=EGLUT; TARGET_LINK_FLAGS= ;;
  armhf)
    TRIPLE=arm-linux-gnueabihf; PROCESSOR=arm
    STRIP=arm-linux-gnueabihf-strip
    TARGET_FEATURES='-march=armv7-a -mfpu=neon -mfloat-abi=hard'
    # The R36S launcher runs this target as an SDL3 Wayland/KMSDRM client.
    # EGLUT cannot initialize a native Wayland display on the 32-bit ROCKNIX
    # stack and exits before it creates a window.
    GAMEWINDOW_SYSTEM=SDL3
    TARGET_LINK_FLAGS='-Wl,--no-as-needed -lEGL' ;;
esac
CC="${CLIENT_CC:-clang}"
CXX="${CLIENT_CXX:-clang++}"
if [ -n "${CLIENT_TARGET_FLAGS+x}" ]; then
  TARGET_FLAGS="$CLIENT_TARGET_FLAGS"
elif [ "$CC" = clang ]; then
  TARGET_FLAGS="--target=$TRIPLE"
else
  # A triple-prefixed GCC already selects its sysroot and target ABI. Passing
  # Clang's --target option to it would fail before CMake's compiler check.
  TARGET_FLAGS=
fi
BUILD=/work/build-$ARCH-$EDITION
# CMAKE_FIND_ROOT_PATH does not affect pkg-config.  Without a target-specific
# search path SDL's cross-build silently misses Wayland/KMSDRM and produces a
# binary that aborts with "No available video device" on ROCKNIX/Sway.
export PKG_CONFIG_LIBDIR="/usr/lib/$TRIPLE/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=/
cmake -S "$WORK" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$PROCESSOR" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="-latomic $TARGET_FLAGS $TARGET_FEATURES ${CLIENT_C_FLAGS:-}" \
  -DCMAKE_CXX_FLAGS="-latomic $TARGET_FLAGS $TARGET_FEATURES ${CLIENT_CXX_FLAGS:-}" \
  -DCMAKE_EXE_LINKER_FLAGS="$TARGET_LINK_FLAGS" \
  -DCMAKE_FIND_ROOT_PATH="/usr/$TRIPLE" \
  -DCMAKE_LIBRARY_PATH="/usr/lib/$TRIPLE" \
  -DGAMEWINDOW_SYSTEM="$GAMEWINDOW_SYSTEM" -DBUILD_UI=OFF -DENABLE_QT_ERROR_UI=OFF \
  -DMSA_DAEMON_PATH=. -DXAL_WEBVIEW_QT_PATH=. -DUSE_OWN_CURL=ON
cmake --build "$BUILD" --target mcpelauncher-client \
  --parallel "${BUILD_JOBS:-2}" --verbose
BIN="$(find "$BUILD" -type f -name mcpelauncher-client -perm /111 -print -quit)"
[ -n "$BIN" ]
mkdir -p /out
cp "$BIN" "/out/mcpelauncher-client.$ARCH.$EDITION"
"$STRIP" --strip-unneeded "/out/mcpelauncher-client.$ARCH.$EDITION"
if [ "$ARCH" = armhf ]; then
  LC_ALL=C grep -aFqi wayland "/out/mcpelauncher-client.$ARCH.$EDITION" || {
    echo "armhf SDL3 client was built without the required Wayland driver" >&2
    exit 1
  }
fi
file "/out/mcpelauncher-client.$ARCH.$EDITION"
