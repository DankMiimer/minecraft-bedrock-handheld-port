#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/platform.sh"

fixture() {
  rm -rf "$TMP/root"
  mkdir -p "$TMP/root"/{proc/device-tree,etc,dev/dri,sys/class/drm,sys/class/input}
  printf 'MemTotal:       1024000 kB\n' >"$TMP/root/proc/meminfo"
  printf 'NAME="%s"\n' "$1" >"$TMP/root/etc/os-release"
  : >"$TMP/root/proc/device-tree/model"
  : >"$TMP/root/proc/device-tree/compatible"
}

fixture Knulli
printf 'Anbernic RG34XX-SP H700\0' >"$TMP/root/proc/device-tree/model"
printf 'allwinner,h700\0' >"$TMP/root/proc/device-tree/compatible"
mkdir -p "$TMP/root/sys/class/graphics/fb0"
printf '720,960\n' >"$TMP/root/sys/class/graphics/fb0/virtual_size"
touch "$TMP/root/dev/mali0" "$TMP/root/dev/disp" "$TMP/root/dev/fb0"
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=none MCPE_TEST_FB_MODE=720x480 \
  mcpe_probe_platform "$TMP/h700.env"
source "$TMP/h700.env"
[ "$MCPE_HOST_PROFILE" = h700 ] && [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = mali ] &&
  [ "$MCPE_FB_MODE" = 720x480 ] && [ "$MCPE_ACTIVE_HEIGHT" = 480 ]

fixture muOS
printf 'Anbernic RG34XX-SP H700\0' >"$TMP/root/proc/device-tree/model"
printf 'allwinner,h700\0' >"$TMP/root/proc/device-tree/compatible"
mkdir -p "$TMP/root/sys/class/drm/card0-DSI-1"
echo connected >"$TMP/root/sys/class/drm/card0-DSI-1/status"
echo 720x480 >"$TMP/root/sys/class/drm/card0-DSI-1/modes"
touch "$TMP/root/dev/dri/card0" "$TMP/root/dev/mali0"
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=none \
  mcpe_probe_platform "$TMP/muos.env"
source "$TMP/muos.env"
[ "$MCPE_HOST_PROFILE" = h700 ] &&
  [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = kmsdrm ] && [ "$MCPE_DRM_MODE" = 720x480 ]

fixture ROCKNIX
printf 'Anbernic RG DS\0' >"$TMP/root/proc/device-tree/model"
printf 'rockchip,rk3568\0' >"$TMP/root/proc/device-tree/compatible"
for name in card0-DSI-1 card0-DSI-2; do
  mkdir -p "$TMP/root/sys/class/drm/$name"
  echo connected >"$TMP/root/sys/class/drm/$name/status"
  echo 640x480 >"$TMP/root/sys/class/drm/$name/modes"
done
touch "$TMP/root/dev/dri/card0"
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=sway \
  mcpe_probe_platform "$TMP/rgds.env"
source "$TMP/rgds.env"
[ "$MCPE_IS_RGDS" = 1 ] && [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = wayland ]

fixture ROCKNIX
printf 'Anbernic RG503\0' >"$TMP/root/proc/device-tree/model"
printf 'rockchip,rk3566\0' >"$TMP/root/proc/device-tree/compatible"
mkdir -p "$TMP/root/sys/class/drm/card0-DSI-1"
echo connected >"$TMP/root/sys/class/drm/card0-DSI-1/status"
echo 1280x720 >"$TMP/root/sys/class/drm/card0-DSI-1/modes"
touch "$TMP/root/dev/dri/card0"
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=sway \
  mcpe_probe_platform "$TMP/rocknix.env"
source "$TMP/rocknix.env"
[ "$MCPE_HOST_PROFILE" = generic ] &&
  [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = wayland ] && [ "$MCPE_DRM_MODE" = 1280x720 ]

fixture dArkOS
printf 'R36S\0' >"$TMP/root/proc/device-tree/model"
printf 'rockchip,rk3326\0' >"$TMP/root/proc/device-tree/compatible"
mkdir -p "$TMP/root/sys/class/drm/card0-DSI-1"
echo connected >"$TMP/root/sys/class/drm/card0-DSI-1/status"
echo 640x480 >"$TMP/root/sys/class/drm/card0-DSI-1/modes"
touch "$TMP/root/dev/dri/card0"
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=armv7l MCPE_TEST_COMPOSITOR=none \
  mcpe_probe_platform "$TMP/r36s.env"
source "$TMP/r36s.env"
[ "$MCPE_HOST_PROFILE" = rk3326 ] &&
  [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = kmsdrm ] && [ "$MCPE_DRM_MODE" = 640x480 ]

# A disconnected Pulse/PipeWire client must not hang host detection.
fixture Generic
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nsleep 30\n' >"$TMP/bin/pactl"
chmod +x "$TMP/bin/pactl"
started="$(date +%s)"
PATH="$TMP/bin:$PATH" MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 \
  MCPE_TEST_COMPOSITOR=none mcpe_probe_platform "$TMP/bounded-audio.env"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 5 ] || { echo "audio capability probe blocked for ${elapsed}s" >&2; exit 1; }
echo "platform fixture tests passed"
