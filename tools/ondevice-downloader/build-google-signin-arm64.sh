#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/google-signin-quick"
OUTPUT="${1:-$SCRIPT_DIR/../../portmaster/minecraftbedrock/minecraftbedrock/downloader/bin/mcpe-signin}"
IMAGE=mcpe-google-signin-arm64:bookworm

mkdir -p "$(dirname "$OUTPUT")"
docker build -t "$IMAGE" "$SOURCE_DIR"
container="$(docker create "$IMAGE")"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
docker cp "$container:/work/mcpe-signin" "$OUTPUT"
chmod 0755 "$OUTPUT"
file "$OUTPUT"
