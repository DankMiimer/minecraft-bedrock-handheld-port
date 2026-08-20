#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 OUTPUT_FILE" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="$1"
mkdir -p "$(dirname "$OUTPUT_FILE")"

aarch64-linux-gnu-gcc -O2 -fPIC -shared -Wall -Wextra \
  -Wl,-z,relro,-z,now -Wl,-soname,libqt-xcb-glx-compat.so \
  "$SCRIPT_DIR/qt-xcb-glx-compat.c" -ldl -o "$OUTPUT_FILE"
aarch64-linux-gnu-strip "$OUTPUT_FILE"
chmod 0755 "$OUTPUT_FILE"
file "$OUTPUT_FILE"
