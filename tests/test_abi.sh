#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/abi.sh"

expect() { # expected has64 has32 usable64 usable32 profile backend arch mem
  local expected="$1"
  shift
  local actual
  actual="$(mcpe_choose_default_abi "$@")"
  [ "$actual" = "$expected" ] || {
    echo "ABI policy: expected $expected, got $actual for: $*" >&2
    exit 1
  }
}

# Regression from the MuOS RG35XX Pro report: 1 GB H700 stays on arm64.
expect arm64 1 1 1 1 h700 mali aarch64 996724
expect arm64 1 1 1 1 h700 mali aarch64 524288

# The 32-bit client remains the preferred compatibility path on R36S/RK3326.
expect armhf 1 1 1 1 rk3326 kmsdrm aarch64 996724
expect armhf 1 1 1 1 generic kmsdrm armv7l 996724
expect armhf 1 1 1 1 generic kmsdrm aarch64 524288

# Composited and ordinary arm64 systems do not fall to armhf because of RAM.
expect arm64 1 1 1 1 generic wayland aarch64 524288
expect arm64 1 1 1 1 generic kmsdrm aarch64 996724

expect armhf 0 1 0 1 generic kmsdrm armv7l 512000
expect arm64 1 0 1 0 generic mali aarch64 512000

echo "ABI policy tests passed"
