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


# --- Loader presence ----------------------------------------------------------
# "Can this system exec the shipped client" is a question about the loader the
# binary asks for, not about `uname -m`. dArkOS RE runs a 64-bit kernel over an
# armhf userland and reported "usable: 64=1" in the issue #1 log while having
# no aarch64 glibc at all.
LOADER_TMP="$(mktemp -d)"
trap 'rm -rf "$LOADER_TMP"' EXIT

loader_root() { rm -rf "$LOADER_TMP/root"; mkdir -p "$LOADER_TMP/root/$1"; }
expect_loader() { # abi expected(0=usable,1=not)
  local actual=0
  MCPE_PROBE_ROOT="$LOADER_TMP/root" mcpe_loader_present "$1" || actual=$?
  [ "$actual" = "$2" ] ||
    { echo "loader $1: expected $2, got $actual" >&2; exit 1; }
}

loader_root lib
: >"$LOADER_TMP/root/lib/ld-linux-aarch64.so.1"
expect_loader arm64 0
expect_loader armhf 1

loader_root lib
: >"$LOADER_TMP/root/lib/ld-linux-armhf.so.3"
expect_loader armhf 0
# The dArkOS RE shape: an armhf userland that must not claim the 64-bit client.
expect_loader arm64 1

# Images that keep the loader outside /lib are still usable.
loader_root usr/lib
: >"$LOADER_TMP/root/usr/lib/ld-linux-aarch64.so.1"
expect_loader arm64 0
loader_root lib64
: >"$LOADER_TMP/root/lib64/ld-linux-aarch64.so.1"
expect_loader arm64 0
loader_root usr/arm-linux-gnueabihf/lib
: >"$LOADER_TMP/root/usr/arm-linux-gnueabihf/lib/ld-linux-armhf.so.3"
expect_loader armhf 0

# A musl-only aarch64 system has a matching kernel and none of the glibc
# loaders these binaries request.
loader_root lib
: >"$LOADER_TMP/root/lib/ld-musl-aarch64.so.1"
expect_loader arm64 1
expect_loader armhf 1

echo "ABI policy tests passed"
