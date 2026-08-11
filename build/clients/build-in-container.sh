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
if [ "$EDITION" = rgds ]; then
  python3 /telemetry/apply_client_patch.py "$WORK"
fi

case "$ARCH" in
  aarch64)
    TRIPLE=aarch64-linux-gnu; PROCESSOR=aarch64
    STRIP=aarch64-linux-gnu-strip; TARGET_FEATURES= ;;
  armhf)
    TRIPLE=arm-linux-gnueabihf; PROCESSOR=arm
    STRIP=arm-linux-gnueabihf-strip; TARGET_FEATURES=-mfpu=neon ;;
esac
CC=clang
CXX=clang++
BUILD=/work/build-$ARCH-$EDITION
cmake -S "$WORK" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$PROCESSOR" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="-latomic --target=$TRIPLE $TARGET_FEATURES" \
  -DCMAKE_CXX_FLAGS="-latomic --target=$TRIPLE $TARGET_FEATURES" \
  -DCMAKE_FIND_ROOT_PATH="/usr/$TRIPLE" \
  -DCMAKE_LIBRARY_PATH="/usr/lib/$TRIPLE" \
  -DGAMEWINDOW_SYSTEM=EGLUT -DBUILD_UI=OFF -DENABLE_QT_ERROR_UI=OFF \
  -DMSA_DAEMON_PATH=. -DXAL_WEBVIEW_QT_PATH=. -DUSE_OWN_CURL=ON
cmake --build "$BUILD" --target mcpelauncher-client \
  --parallel "${BUILD_JOBS:-2}" --verbose
BIN="$(find "$BUILD" -type f -name mcpelauncher-client -perm /111 -print -quit)"
[ -n "$BIN" ]
mkdir -p /out
cp "$BIN" "/out/mcpelauncher-client.$ARCH.$EDITION"
"$STRIP" --strip-unneeded "/out/mcpelauncher-client.$ARCH.$EDITION"
file "/out/mcpelauncher-client.$ARCH.$EDITION"
