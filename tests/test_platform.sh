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
  # The host's own CFW must never leak into a fixture's identity.
  unset CFW_NAME MCPE_CFW_OVERRIDE MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY
}

# Captured from the reference RG34XX-SP on Knulli (2026-08-23). Every string
# here is what the device actually reports rather than a plausible stand-in:
# its os-release calls itself Batocera except for OS_NAME, the compatible
# says h616/sun50iw9p1 rather than h700, and there is no /dev/dri at all.
fixture Knulli
cat >"$TMP/root/etc/os-release" <<'OSREL'
NAME=Batocera.linux
PRETTY_NAME="Batocera.linux 42"
VERSION=42
ID=buildroot
VERSION_ID=2024.11
OS_NAME="knulli"
OS_DATE=20260511
OSREL
printf 'Anbernic RG34XX-SP\0' >"$TMP/root/proc/device-tree/model"
printf 'allwinner,h616\0arm,sun50iw9p1\0' >"$TMP/root/proc/device-tree/compatible"
mkdir -p "$TMP/root/sys/class/graphics/fb0"
printf '720,960\n' >"$TMP/root/sys/class/graphics/fb0/virtual_size"
touch "$TMP/root/dev/mali0" "$TMP/root/dev/disp" "$TMP/root/dev/fb0"
rmdir "$TMP/root/dev/dri" 2>/dev/null || true
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=none MCPE_TEST_FB_MODE=720x480 \
  mcpe_probe_platform "$TMP/h700.env"
source "$TMP/h700.env"
[ "$MCPE_HOST_PROFILE" = h700 ] && [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = mali ] &&
  [ "$MCPE_FB_MODE" = 720x480 ] && [ "$MCPE_ACTIVE_HEIGHT" = 480 ]
[ "$MCPE_HAS_DRM" = 0 ] || { echo "Knulli reference device exposes no DRM node" >&2; exit 1; }
# The device does export CFW_NAME=knulli at launch (via device_info.txt), but
# this fixture exercises the os-release fallback, where the file names its
# Batocera upstream everywhere except OS_NAME.
[ "$MCPE_CFW" = knulli ] && [ "$MCPE_CFW_CONFIDENCE" = explicit ]

# Captured from a reference RG34XX-SP on muOS 2601.0 JACARANDA (2026-08-24).
# This fixture previously guessed, and guessed wrong in the way that matters:
# it gave the device /dev/dri and expected the kmsdrm backend. The hardware is
# the same H700 as the Knulli reference and exposes no DRM node at all, so the
# correct answer is the mali backend. It also reports its model as the bare SoC
# string "sun50iw9" rather than a product name, which is why the h700 profile
# has to match on the compatible rather than on the model.
fixture muOS
cat >"$TMP/root/etc/os-release" <<'OSREL'
NAME=MustardOS
VERSION="2601.0 (JACARANDA)"
ID=muos
VERSION_ID=2601.0
PRETTY_NAME="MustardOS 2601.0 (JACARANDA)"
OSREL
printf 'sun50iw9\0' >"$TMP/root/proc/device-tree/model"
printf 'allwinner,h616\0arm,sun50iw9p1\0' >"$TMP/root/proc/device-tree/compatible"
mkdir -p "$TMP/root/sys/class/graphics/fb0"
printf '720,960\n' >"$TMP/root/sys/class/graphics/fb0/virtual_size"
touch "$TMP/root/dev/mali0" "$TMP/root/dev/disp" "$TMP/root/dev/fb0"
rmdir "$TMP/root/dev/dri" 2>/dev/null || true
MCPE_PROBE_ROOT="$TMP/root" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=none \
  MCPE_TEST_FB_MODE=720x480 mcpe_probe_platform "$TMP/muos.env"
source "$TMP/muos.env"
[ "$MCPE_HOST_PROFILE" = h700 ] &&
  [ "$MCPE_GRAPHICS_BACKEND_RESOLVED" = mali ] && [ "$MCPE_FB_MODE" = 720x480 ]
[ "$MCPE_HAS_DRM" = 0 ] || { echo "muOS reference device exposes no DRM node" >&2; exit 1; }
# The panel is 720x480 while fb0 reports a 720x960 virtual size, so the visible
# height must come from the mode rather than from virtual_size.
[ "$MCPE_ACTIVE_HEIGHT" = 480 ] || { echo "muOS panel height must ignore virtual_size" >&2; exit 1; }
[ "$MCPE_CFW" = muos ] && [ "$MCPE_CFW_CONFIDENCE" = explicit ]

# Captured from the reference RGDS on ROCKNIX (2026-08-23).
fixture ROCKNIX
printf 'OS_NAME="ROCKNIX"\nOS_VERSION="20260710"\nHW_DEVICE="RK3566"\n' >"$TMP/root/etc/os-release"
printf 'Anbernic RG DS\0' >"$TMP/root/proc/device-tree/model"
printf 'anbernic,rg-ds\0rockchip,rk3568\0' >"$TMP/root/proc/device-tree/compatible"
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
[ "$MCPE_CFW" = rocknix ]

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
[ "$MCPE_CFW" = rocknix ] && [ "$MCPE_CFW_CONFIDENCE" = explicit ]

# No dArkOS reference device; constructed from the issue #1 log.
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
# "dArkOS" and "dArkOSRE" both resolve to the shared ArkOS-family behaviour.
[ "$MCPE_CFW" = arkos ] && [ "$MCPE_CFW_CONFIDENCE" = explicit ]

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

# --- Canonical CFW identity ----------------------------------------------------
# These replace four ad-hoc detectors that had drifted apart, so the resolver is
# pinned directly rather than only through the capability fixtures above.
cfw_root() { # dir-under-root...
  rm -rf "$TMP/cfwroot"
  mkdir -p "$TMP/cfwroot/etc"
  local d
  for d in "$@"; do mkdir -p "$TMP/cfwroot/$d"; done
}
expect_cfw() { # expected-id expected-confidence
  local want_id="$1" want_conf="$2"
  MCPE_PROBE_ROOT="$TMP/cfwroot" mcpe_resolve_cfw
  [ "$MCPE_CFW" = "$want_id" ] ||
    { echo "cfw: expected $want_id, got $MCPE_CFW" >&2; exit 1; }
  [ "$MCPE_CFW_CONFIDENCE" = "$want_conf" ] ||
    { echo "cfw $want_id: expected $want_conf, got $MCPE_CFW_CONFIDENCE" >&2; exit 1; }
}

# PortMaster's CFW_NAME outranks os-release: a system that names itself through
# the launcher is the most direct evidence available.
cfw_root
printf 'NAME="Batocera"\n' >"$TMP/cfwroot/etc/os-release"
CFW_NAME=Knulli expect_cfw knulli explicit
unset CFW_NAME

# Knulli is a Batocera derivative and must never be reported as its upstream.
cfw_root
printf 'NAME="Knulli"\nID=batocera\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw knulli explicit

# A derivative commonly keeps its upstream's NAME and announces itself only in
# PRETTY_NAME. Stopping at the first field that matched anything would report
# the upstream and lose every Knulli-specific behaviour.
cfw_root
printf 'NAME="Batocera"\nID=batocera\nPRETTY_NAME="Knulli 40 (Scarab)"\n' \
  >"$TMP/cfwroot/etc/os-release"
expect_cfw knulli explicit

# The same shape must still report plain Batocera when nothing more specific
# appears anywhere in the file.
cfw_root
printf 'NAME="Batocera"\nID=batocera\nPRETTY_NAME="Batocera 40"\n' \
  >"$TMP/cfwroot/etc/os-release"
expect_cfw batocera explicit

# Every ArkOS-family clone shares one identity, because the port branches on
# their shared layout and display path rather than on the brand.
for name in ArkOS dArkOS dArkOSRE "DarkOS RE"; do
  cfw_root
  printf 'NAME="%s"\n' "$name" >"$TMP/cfwroot/etc/os-release"
  expect_cfw arkos explicit
done

# Layout inference, for systems that name themselves something unhelpful.
cfw_root opt/muos/script/var/global
printf 'NAME="Buildroot"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw muos inferred

cfw_root mnt/sdcard/MUOS
printf 'NAME="Buildroot"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw muos inferred

cfw_root opt/system/Tools/PortMaster
printf 'NAME="Ubuntu"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw arkos inferred

cfw_root storage/.config storage/roms
printf 'NAME="LibreELEC"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw rocknix inferred

cfw_root userdata/system
printf 'NAME="Linux"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw batocera inferred

# muOS layout wins over an ArkOS-style tools directory left on the same card.
cfw_root opt/muos opt/system/Tools/PortMaster
printf 'NAME="Linux"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw muos inferred

# Nothing recognisable must produce a definite-looking answer.
cfw_root
printf 'NAME="Debian"\n' >"$TMP/cfwroot/etc/os-release"
expect_cfw unknown none

cfw_root
MCPE_CFW_OVERRIDE=rocknix expect_cfw rocknix override
unset MCPE_CFW_OVERRIDE

# mcpe_is_cfw accepts several ids and resolves lazily when none is cached.
cfw_root
printf 'NAME="ROCKNIX"\n' >"$TMP/cfwroot/etc/os-release"
export MCPE_PROBE_ROOT="$TMP/cfwroot"
mcpe_resolve_cfw
mcpe_is_cfw knulli rocknix || { echo "mcpe_is_cfw missed a listed id" >&2; exit 1; }
! mcpe_is_cfw muos arkos || { echo "mcpe_is_cfw matched an unlisted id" >&2; exit 1; }
unset MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY
mcpe_is_cfw rocknix || { echo "mcpe_is_cfw did not resolve on demand" >&2; exit 1; }

# CFW_NAME arrives only after PortMaster's control files are sourced. Any
# mcpe_is_cfw call made before that must not pin the wrong answer for the rest
# of the run -- that would silently disable every per-CFW behaviour at once.
cfw_root
printf 'NAME="Debian"\n' >"$TMP/cfwroot/etc/os-release"
unset CFW_NAME MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY
! mcpe_is_cfw knulli || { echo "unknown host matched knulli" >&2; exit 1; }
[ "$MCPE_CFW" = unknown ] || { echo "expected a cached unknown" >&2; exit 1; }
CFW_NAME=Knulli
mcpe_is_cfw knulli ||
  { echo "late CFW_NAME was ignored because of a stale cache" >&2; exit 1; }
unset CFW_NAME MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY MCPE_PROBE_ROOT

# --- Launch stage breadcrumb ---------------------------------------------------
# The point of the breadcrumb is that the *previous* run's last stage survives a
# device that never got to write a log.
rm -rf "$TMP/stagedir"
mcpe_stage_begin "$TMP/stagedir"
[ -z "$MCPE_STAGE_PREV" ] || { echo "first run reported a previous stage" >&2; exit 1; }
[ "$(cut -f1 <"$TMP/stagedir/stage.txt")" = boot ] ||
  { echo "stage_begin did not record boot" >&2; exit 1; }
mcpe_stage client-exec
[ "$(cut -f1 <"$TMP/stagedir/stage.txt")" = client-exec ] ||
  { echo "stage was not overwritten in place" >&2; exit 1; }
mcpe_stage_begin "$TMP/stagedir"
[ "$MCPE_STAGE_PREV" = client-exec ] ||
  { echo "previous stage lost across runs: $MCPE_STAGE_PREV" >&2; exit 1; }
[ "$(cut -f1 <"$TMP/stagedir/stage.prev.txt")" = client-exec ] ||
  { echo "stage.prev.txt not retained for the support bundle" >&2; exit 1; }

# Child scripts source common.sh again. Re-sourcing must not disarm the
# breadcrumb the parent opened: a live launch on the reference RG34XX-SP lost
# every stage written by run_bedrock.sh and weston_launch.sh this way, which is
# precisely the `client-exec` / `first-frame` evidence a hang report needs.
mcpe_stage abi
(
  # shellcheck disable=SC1090
  . "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/common.sh"
  [ -n "${MCPE_STAGE_FILE:-}" ] ||
    { echo "re-sourcing common.sh cleared MCPE_STAGE_FILE" >&2; exit 1; }
  mcpe_stage client-exec
)
[ "$(cut -f1 <"$TMP/stagedir/stage.txt")" = client-exec ] ||
  { echo "a child process could not advance the breadcrumb" >&2; exit 1; }

# --- UI zoom target -----------------------------------------------------------
# 1.21-era Bedrock ignores every reported-size and DPI knob, so "UI zoom" has to
# shrink the real surface. Both steps were measured on the RG34XX-SP: 480x320
# and 576x384 hold through a session, and both are 16-aligned.
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/common.sh"

[ "$(mcpe_zoom_target 720 480 1.5)" = "480 320" ] ||
  { echo "1.5x zoom did not resolve 720x480 to 480x320" >&2; exit 1; }
[ "$(mcpe_zoom_target 720 480 1.25)" = "576 384" ] ||
  { echo "1.25x zoom did not resolve 720x480 to 576x384" >&2; exit 1; }
mcpe_fb_mode_aligned $(mcpe_zoom_target 720 480 1.25) ||
  { echo "the 1.25x target is not 16-aligned" >&2; exit 1; }
mcpe_fb_mode_aligned $(mcpe_zoom_target 720 480 1.5) ||
  { echo "the 1.5x target is not 16-aligned" >&2; exit 1; }
[ "$(mcpe_zoom_target 720 480 1)" = "720 480" ] ||
  { echo "zoom off changed the panel size" >&2; exit 1; }
[ "$(mcpe_zoom_target 720 480)" = "720 480" ] ||
  { echo "missing zoom argument changed the panel size" >&2; exit 1; }
# A panel whose target is not 16-aligned must be caught by the gate rather than
# quietly stretched onto a size this stack cannot hold.
[ "$(mcpe_zoom_target 640 480 1.5)" = "426 320" ] ||
  { echo "1.5x zoom did not keep the exact ratio on a 640x480 panel" >&2; exit 1; }
! mcpe_fb_mode_aligned $(mcpe_zoom_target 640 480 1.5) ||
  { echo "an unaligned zoom target was accepted" >&2; exit 1; }
# An unknown factor must not invent a mode.
[ "$(mcpe_zoom_target 720 480 2)" = "720 480" ] ||
  { echo "an unsupported zoom factor was not ignored" >&2; exit 1; }
[ "$(mcpe_zoom_target "" "" 1.5)" = " " ] ||
  { echo "non-numeric panel size was not passed through" >&2; exit 1; }

# fbset reports success for sizes this graphics stack cannot hold, and the
# kernel's mode list is a log of what was requested rather than a capability
# list, so alignment is the gate. 480x320 holds on the RG34XX-SP; 600x400 and
# 360x240 do not, and are exactly the unaligned ones.
mcpe_fb_mode_aligned 480 320 ||
  { echo "a 16-aligned size was rejected" >&2; exit 1; }
! mcpe_fb_mode_aligned 600 400 ||
  { echo "600x400 was accepted despite not holding on hardware" >&2; exit 1; }
! mcpe_fb_mode_aligned 360 240 ||
  { echo "360x240 was accepted despite desynchronising the framebuffer" >&2; exit 1; }
! mcpe_fb_mode_aligned "" "" ||
  { echo "an empty size was accepted" >&2; exit 1; }

echo "platform fixture tests passed"
