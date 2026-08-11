#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/artifacts/clients}"
ENGINE="${CONTAINER_ENGINE:-docker}"
command -v "$ENGINE" >/dev/null 2>&1 || {
  echo "$ENGINE is required for pinned client builds" >&2; exit 1;
}
mkdir -p "$OUT"
build_one() {
  local arch="$1" edition="$2" destination="$3"
  local temp="$OUT/.container-$arch-$edition"
  rm -rf "$temp"; mkdir -p "$temp"
  "$ENGINE" build --file "$ROOT/build/clients/Dockerfile" \
    --build-arg "TARGET_ARCH=$arch" --build-arg "EDITION=$edition" \
    --output "type=local,dest=$temp" "$ROOT"
  mv "$temp/mcpelauncher-client.$arch.$edition" "$destination"
  rmdir "$temp"
}
build_one aarch64 standard "$OUT/mcpelauncher-client.aarch64.standard"
build_one armhf standard "$OUT/mcpelauncher-client.armhf.standard"
build_one aarch64 rgds "$OUT/mcpelauncher-client.aarch64.rgds"
echo "Pinned client artifacts built in $OUT"
