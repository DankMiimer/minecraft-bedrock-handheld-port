#!/bin/bash
set -euo pipefail

# Cross-build minecraft-linux/Google-Play-API for the RG34XXSP prototype.
#
# Usage:
#   build-gplaydl-arm64.sh GOOGLE_PLAY_API_SOURCE ARM64_LIB_DIR OUTPUT_DIR
#
# ARM64_LIB_DIR must contain libcurl.so.4, libprotobuf.so.32 and libz.so.1
# from the target runtime. Headers and protoc come from Ubuntu 24.04/WSL.

if [ "$#" -ne 3 ]; then
  echo "usage: $0 GOOGLE_PLAY_API_SOURCE ARM64_LIB_DIR OUTPUT_DIR" >&2
  exit 2
fi

SOURCE_DIR="$(realpath "$1")"
ARM64_LIB_DIR="$(realpath "$2")"
OUTPUT_DIR="$(mkdir -p "$3" && realpath "$3")"
BUILD_DIR="${TMPDIR:-/tmp}/mcpe-gplaydl-arm64"
HEADER_DIR="${TMPDIR:-/tmp}/mcpe-gplaydl-cross-headers"

case "$BUILD_DIR:$HEADER_DIR" in
  */mcpe-gplaydl-arm64:*/mcpe-gplaydl-cross-headers) ;;
  *) echo "refusing unsafe temporary build paths" >&2; exit 2 ;;
esac

ln -sfn libcurl.so.4 "$ARM64_LIB_DIR/libcurl.so"
ln -sfn libprotobuf.so.32 "$ARM64_LIB_DIR/libprotobuf.so"
ln -sfn libz.so.1 "$ARM64_LIB_DIR/libz.so"

rm -rf "$BUILD_DIR" "$HEADER_DIR"
mkdir -p "$HEADER_DIR"
# Ubuntu keeps curl's generated headers in a host-architecture directory.
# Stage only curl/ so that directory cannot shadow the ARM64 libc headers.
cp -a /usr/include/x86_64-linux-gnu/curl "$HEADER_DIR/curl"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_SKIP_RPATH=TRUE \
  -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
  -DCURL_INCLUDE_DIR="$HEADER_DIR" \
  -DCURL_LIBRARY="$ARM64_LIB_DIR/libcurl.so" \
  -DZLIB_INCLUDE_DIR=/usr/include \
  -DZLIB_LIBRARY="$ARM64_LIB_DIR/libz.so" \
  -DProtobuf_INCLUDE_DIR=/usr/include \
  -DProtobuf_LIBRARY="$ARM64_LIB_DIR/libprotobuf.so" \
  -DProtobuf_PROTOC_EXECUTABLE=/usr/bin/protoc

cmake --build "$BUILD_DIR" --target gplaydl gplayver -j "$(nproc)"
aarch64-linux-gnu-strip "$BUILD_DIR/gplaydl" "$BUILD_DIR/gplayver"
install -m 0755 "$BUILD_DIR/gplaydl" "$OUTPUT_DIR/gplaydl"
install -m 0755 "$BUILD_DIR/gplayver" "$OUTPUT_DIR/gplayver"
install -m 0644 "$SOURCE_DIR/LICENSE" "$OUTPUT_DIR/LICENSE.google-play-api"

file "$OUTPUT_DIR/gplaydl" "$OUTPUT_DIR/gplayver"
