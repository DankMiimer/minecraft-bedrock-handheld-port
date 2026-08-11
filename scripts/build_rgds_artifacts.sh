#!/bin/bash
# Reproducible RGDS artifact build entrypoint. No workspace-specific paths.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/artifacts/rgds}"
LEVELDB_COMMIT=4846fc72c7eda860b1bcf6efc58920a9273da928
LEVELDB_SRC="${LEVELDB_SRC:-$ROOT/build/deps/leveldb-mcpe}"
WAYLAND_LIB="${WAYLAND_LIB:-/usr/lib/aarch64-linux-gnu/libwayland-client.so}"
AARCH64_ZLIB="${AARCH64_ZLIB:-/usr/lib/aarch64-linux-gnu/libz.a}"
mkdir -p "$OUT"

if [ ! -d "$LEVELDB_SRC/.git" ]; then
  mkdir -p "$(dirname "$LEVELDB_SRC")"
  git clone --filter=blob:none --no-checkout https://github.com/Amulet-Team/leveldb-mcpe "$LEVELDB_SRC"
  git -C "$LEVELDB_SRC" checkout --detach "$LEVELDB_COMMIT"
fi
[ "$(git -C "$LEVELDB_SRC" rev-parse HEAD)" = "$LEVELDB_COMMIT" ] || {
  echo "LEVELDB_SRC must be the pinned commit $LEVELDB_COMMIT" >&2
  exit 1
}
LDB_CMAKE="$LEVELDB_SRC/CMakeLists.txt"
if grep -q 'add_library(leveldb_mcpe SHARED)' "$LDB_CMAKE" &&
   grep -Eq 'target_link_libraries\( *leveldb_mcpe PRIVATE zlibstatic *\)' "$LDB_CMAKE"; then
  sed -i 's/add_library(leveldb_mcpe SHARED)/add_library(leveldb_mcpe STATIC)/' "$LDB_CMAKE"
  sed -Ei 's/target_link_libraries\( *leveldb_mcpe PRIVATE zlibstatic *\)/target_link_libraries(leveldb_mcpe PRIVATE ZLIB::ZLIB)/' "$LDB_CMAKE"
fi
grep -q 'add_library(leveldb_mcpe STATIC)' "$LDB_CMAKE" &&
  grep -Eq 'target_link_libraries\( *leveldb_mcpe PRIVATE ZLIB::ZLIB *\)' "$LDB_CMAKE" || {
    echo "leveldb-mcpe checkout does not match the pinned static build recipe" >&2
    exit 1
  }
[ -f "$WAYLAND_LIB" ] || { echo "missing aarch64 Wayland client library: $WAYLAND_LIB" >&2; exit 1; }
[ -f "$AARCH64_ZLIB" ] || { echo "missing aarch64 zlib library: $AARCH64_ZLIB" >&2; exit 1; }

AARCH64_CC="${AARCH64_CC:-aarch64-linux-gnu-gcc}"
AARCH64_CXX="${AARCH64_CXX:-aarch64-linux-gnu-g++}"
AARCH64_STRIP="${AARCH64_STRIP:-aarch64-linux-gnu-strip}"
WAYLAND_SCANNER="${WAYLAND_SCANNER:-wayland-scanner}"
XDG_SHELL_XML="${XDG_SHELL_XML:-/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml}"

BD="$ROOT/bottomscreen/bottomd"
PROTO_OUT="$ROOT/build/generated/wayland-protocol"
command -v "$WAYLAND_SCANNER" >/dev/null 2>&1 || {
  echo "missing Wayland scanner: $WAYLAND_SCANNER" >&2
  exit 1
}
[ -f "$XDG_SHELL_XML" ] || { echo "missing xdg-shell protocol: $XDG_SHELL_XML" >&2; exit 1; }
rm -rf "$PROTO_OUT"
mkdir -p "$PROTO_OUT"
"$WAYLAND_SCANNER" client-header "$XDG_SHELL_XML" "$PROTO_OUT/xdg-shell-client-protocol.h"
"$WAYLAND_SCANNER" private-code "$XDG_SHELL_XML" "$PROTO_OUT/xdg-shell-protocol.c"
"$AARCH64_CC" -O2 -ffunction-sections -fdata-sections -Wall -Wextra -std=c11 \
  -DBOTTOMD_HAVE_WAYLAND -I"$BD/wl_include" -I"$BD" -I"$PROTO_OUT" \
  -o "$OUT/bottomd" \
  "$BD/bottomd.c" "$BD/companion.c" "$BD/draw.c" "$BD/gamepad.c" \
  "$BD/pages.c" "$BD/paneltouch.c" "$BD/screenflip.c" "$BD/texture.c" "$BD/tiles.c" \
  "$BD/touchfwd.c" "$BD/worldinfo.c" "$BD/backend_ppm.c" \
  "$BD/backend_fbdev.c" "$BD/backend_wayland.c" "$PROTO_OUT/xdg-shell-protocol.c" \
  "$WAYLAND_LIB" -lrt -lm -lpng -Wl,--allow-shlib-undefined,--gc-sections

LDB_BUILD="$LEVELDB_SRC/build-aarch64-static"
cmake -S "$LEVELDB_SRC" -B "$LDB_BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER="$AARCH64_CC" -DCMAKE_CXX_COMPILER="$AARCH64_CXX" \
  -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
  -DZLIB_LIBRARY="$AARCH64_ZLIB" \
  -DZLIB_INCLUDE_DIR=/usr/include
cmake --build "$LDB_BUILD" --target leveldb_mcpe --parallel
"$AARCH64_CXX" -O2 -std=c++17 -DDLLX= \
  -o "$OUT/bedrockmap" "$ROOT/bottomscreen/bedrockmap/bedrockmap.cpp" \
  -I"$LEVELDB_SRC/include" "$LDB_BUILD/libleveldb_mcpe.a" "$AARCH64_ZLIB" -lrt -lpthread

for binary in "$OUT/bottomd" "$OUT/bedrockmap"; do "$AARCH64_STRIP" --strip-unneeded "$binary"; done
echo "RGDS companion artifacts built in $OUT"
