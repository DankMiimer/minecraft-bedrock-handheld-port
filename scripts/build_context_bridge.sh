#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/artifacts/common/crusty-context-v1.so}"
CC="${AARCH64_CC:-aarch64-linux-gnu-gcc}"
STRIP="${AARCH64_STRIP:-aarch64-linux-gnu-strip}"
mkdir -p "$(dirname "$OUT")"
"$CC" -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Werror \
  -shared "$ROOT/source_release/runtime/crusty_context_v1.c" \
  -ldl -Wl,--no-undefined,-z,relro,-z,now \
  -o "$OUT"
"$STRIP" --strip-unneeded "$OUT"
"$CC" -Wall -Wextra -Werror \
  "$ROOT/source_release/runtime/test_crusty_context_v1.c" -ldl \
  -o "${OUT}.test"
file "$OUT"
echo "Built Crusty context API v1 module: $OUT"
