#!/bin/sh
# Build a probe fixture from whatever firmware this is running on, so tests can
# keep working against a real capture once the hardware is gone.
#
# Firmware-agnostic by construction: it captures the paths mcpe_probe_platform
# reads, and records what it found rather than what it expected. Run it on the
# device and copy /tmp/mcpe-fixture.tar back.
#
#   sh tools/capture-fixture.sh [name]
#
# It never touches the downloader state directory, which holds a live Google
# device token. Nothing here contains credentials or account identifiers.
set -u
NAME="${1:-$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)}"
NAME="${NAME:-unknown}"
F=/tmp/mcpe-fixture
rm -rf "$F"; mkdir -p "$F"

mark() { mkdir -p "$(dirname "$F/$1")"; : >"$F/$1"; }
copy() { [ -r "$2" ] || return 0; mkdir -p "$(dirname "$F/$1")"; cat "$2" >"$F/$1" 2>/dev/null; }

# --- identity and memory -----------------------------------------------------
copy etc/os-release /etc/os-release
copy proc/consoles /proc/consoles
copy proc/bus/input/devices /proc/bus/input/devices
mkdir -p "$F/proc/device-tree"
cat /proc/device-tree/model >"$F/proc/device-tree/model" 2>/dev/null
cat /proc/device-tree/compatible >"$F/proc/device-tree/compatible" 2>/dev/null
head -8 /proc/meminfo >"$F/proc/meminfo" 2>/dev/null
{ grep -m1 -E 'Features' /proc/cpuinfo; echo "processors=$(grep -c ^processor /proc/cpuinfo)"; } \
  >"$F/proc/cpuinfo" 2>/dev/null

# --- display -----------------------------------------------------------------
copy sys/class/vtconsole/vtcon0/name /sys/class/vtconsole/vtcon0/name
copy sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/virtual_size
# DRM connectors carry real content the probe parses for modes.
mkdir -p "$F/sys/class/drm"
for c in /sys/class/drm/*; do
  [ -e "$c" ] || continue
  n=$(basename "$c")
  copy "sys/class/drm/$n/status" "$c/status"
  copy "sys/class/drm/$n/modes" "$c/modes"
  [ -d "$c" ] && mkdir -p "$F/sys/class/drm/$n"
done
for d in /dev/dri/card0 /dev/dri/card1 /dev/dri/renderD128 /dev/mali0 /dev/mali \
         /dev/disp /dev/fb0; do
  [ -e "$d" ] && mark "${d#/}"
done

# --- input -------------------------------------------------------------------
for e in /sys/class/input/event*; do
  [ -e "$e" ] || continue
  n=$(basename "$e")
  copy "sys/class/input/$n/device/name" "$e/device/name"
  copy "sys/class/input/$n/device/phys" "$e/device/phys"
done
for j in /dev/input/js0 /dev/input/js1; do [ -e "$j" ] && mark "${j#/}"; done

# --- audio -------------------------------------------------------------------
for a in /dev/snd/controlC0 /dev/snd/controlC1 /run/pipewire-0 /run/pipewire/pipewire-0 \
         /run/pulse/native /var/run/pulse/native /usr/share/pipewire/client.conf; do
  [ -e "$a" ] && mark "${a#/}"
done
for r in /run/*-runtime-dir/pulse/native /run/*-runtime-dir/pipewire-0; do
  [ -e "$r" ] && mark "${r#/}"
done

# --- ABI and libraries -------------------------------------------------------
for l in /lib/ld-linux-aarch64.so.1 /usr/lib/ld-linux-aarch64.so.1 \
         /lib/ld-linux-armhf.so.3 /usr/lib32/ld-linux-armhf.so.3 \
         /usr/arm-linux-gnueabihf/lib/ld-linux-armhf.so.3 \
         /usr/lib/libSDL2-2.0.so.0 /usr/lib/libEGL.so.1 /usr/lib/libGLESv2.so.2 \
         /usr/lib/libEGL_mesa.so.0 /usr/lib/libGLX_mesa.so.0 /usr/lib/libgbm.so.1 \
         /usr/lib/libcom_err.so.2 /usr/lib32/libcom_err.so.2; do
  [ -e "$l" ] && mark "${l#/}"
done
for m in /usr/lib/dri /usr/lib/aarch64-linux-gnu/dri; do
  [ -d "$m" ] && { mkdir -p "$F${m}"; for so in "$m"/*_dri.so; do
      [ -e "$so" ] && mark "${so#/}"; done; }
done

# --- tools the probe asks about ----------------------------------------------
# command -v cannot be captured, so a tool is recorded as a marker at its own
# resolved path. Nothing is executable in a fixture; existence is the whole
# claim.
for t in pactl nproc Xwayland weston sway readelf; do
  path="$(command -v "$t" 2>/dev/null)" || continue
  [ -n "$path" ] && mark "${path#/}"
done

# --- reference, for humans rather than the probe -----------------------------
mkdir -p "$F/reference"
fbset 2>/dev/null >"$F/reference/fbset.txt"
uname -a >"$F/reference/uname.txt" 2>/dev/null
{
  echo "captured_name=$NAME"
  echo "dev_dri=$([ -e /dev/dri ] && echo present || echo absent)"
  echo "sys_class_drm_entries=$(ls /sys/class/drm 2>/dev/null | wc -l)"
  echo "connected_connectors=$(grep -l '^connected$' /sys/class/drm/*/status 2>/dev/null | wc -l)"
  echo "run_pulse=$([ -e /run/pulse ] && echo present || echo absent)"
  echo "mesa_dri=$([ -d /usr/lib/dri ] && echo present || echo absent)"
  echo "xwayland=$(command -v Xwayland || echo absent)"
  echo "sway_running=$(pidof sway >/dev/null 2>&1 && echo yes || echo no)"
  echo "pipewire_running=$(pidof pipewire >/dev/null 2>&1 && echo yes || echo no)"
  echo "pactl=$(command -v pactl || echo absent)"
  echo "nproc=$(command -v nproc || echo absent)"
} >"$F/reference/absences.txt"

cat >"$F/MANIFEST" <<EOM
Captured by tools/capture-fixture.sh from a live device.

  name:     $NAME
  os:       $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')
  model:    $(tr -d '\000' </proc/device-tree/model 2>/dev/null)
  kernel:   $(uname -r 2>/dev/null)

Real content: etc/os-release, proc/*, sys/class/drm/*/status and modes,
sys/class/input/event*/device/{name,phys}, sys/class/graphics, reference/*.

Empty markers, because device nodes, sockets and shared libraries cannot be
copied and the probe only tests them for existence: everything under dev/ and
run/, the loader and library paths, and the Mesa dri directory.

Contains no credential material. Nothing from the downloader state directory,
no tokens, no account identifiers.

A compositor, a running daemon and an ioctl cannot be captured. Tests that need
those supply MCPE_TEST_COMPOSITOR or similar, and should say so.
EOM

tar cf /tmp/mcpe-fixture.tar -C /tmp mcpe-fixture
echo "name: $NAME"
echo "files: $(find "$F" -type f | wc -l)"
echo "tar: /tmp/mcpe-fixture.tar ($(wc -c </tmp/mcpe-fixture.tar) bytes)"
