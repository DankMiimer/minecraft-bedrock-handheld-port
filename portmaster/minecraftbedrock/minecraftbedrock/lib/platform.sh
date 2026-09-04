#!/bin/bash
# Capability resolver. OS names annotate quirks; capabilities select backends.

# mcpe_resolve_cfw lives in common.sh so that migrate_data.sh, which runs
# before the capability probe, can use it too. Load it here as well so this
# file stays usable on its own (tests/test_platform.sh sources only this one).
if ! type mcpe_resolve_cfw >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

mcpe_first_drm_mode() {
  local connector mode
  local probe_root="${MCPE_PROBE_ROOT:-}"
  for connector in "$probe_root"/sys/class/drm/card*-*; do
    [ -r "$connector/status" ] && [ "$(cat "$connector/status" 2>/dev/null)" = connected ] || continue
    mode="$(sed -n '/^[0-9][0-9]*x[0-9][0-9]*$/ {p;q}' "$connector/modes" 2>/dev/null)"
    [ -n "$mode" ] && { printf '%s|%s\n' "$(basename "$connector")" "$mode"; return 0; }
  done
  return 1
}

mcpe_drm_inventory() {
  local connector status modes=""
  local probe_root="${MCPE_PROBE_ROOT:-}"
  for connector in "$probe_root"/sys/class/drm/card*-*; do
    [ -r "$connector/status" ] || continue
    status="$(cat "$connector/status" 2>/dev/null)"
    modes="$(tr '\n' ',' <"$connector/modes" 2>/dev/null || true)"
    printf '%s:%s:%s;' "$(basename "$connector")" "$status" "$modes"
  done
}

# Optional desktop-audio clients can block forever when their session daemon
# is not reachable (observed on ROCKNIX over SSH). Never let a capability
# probe stall the launcher. `timeout` is used only when the host provides it;
# otherwise this optional query is skipped and process/socket detection below
# still selects PipeWire or ALSA safely.
mcpe_bounded_probe() {
  local seconds="$1"
  shift
  command -v timeout >/dev/null 2>&1 || return 1
  timeout "$seconds" "$@" >/dev/null 2>&1
}

# A fixture cannot hold a live socket or a running daemon, so under a probe root
# the captured marker's existence stands in for both. On a real device the
# stricter tests are kept exactly as they were. Without this, audio was the one
# capability a captured fixture could not express: ALSA was probed under the
# root while PipeWire and Pulse were found with pidof and -S against absolute
# paths, so a muOS capture resolved alsa where the device resolved pipewire.
mcpe_probe_socket() { # absolute path
  if [ -n "${MCPE_PROBE_ROOT:-}" ]; then
    [ -e "${MCPE_PROBE_ROOT}$1" ]
  else
    [ -S "$1" ]
  fi
}

mcpe_probe_daemon() { # process name
  [ -z "${MCPE_PROBE_ROOT:-}" ] || return 1
  pidof "$1" >/dev/null 2>&1
}

mcpe_probe_tool() { # command name
  if [ -n "${MCPE_PROBE_ROOT:-}" ]; then
    # A capture cannot hold an executable, so the marker for a tool is the tool's
    # own path. Anything else invents a correspondence: pactl on Knulli is what
    # makes that device report Pulse, and it has no /run/pulse at all.
    [ -e "${MCPE_PROBE_ROOT}/usr/bin/$1" ] || [ -e "${MCPE_PROBE_ROOT}/bin/$1" ] ||
      [ -e "${MCPE_PROBE_ROOT}/usr/sbin/$1" ]
  else
    command -v "$1" >/dev/null 2>&1
  fi
}

mcpe_probe_platform() { # output env file
  local out="$1" model compatible os_name arch mem compositor drm_pair connector mode
  local has_mali=0 has_mesa=0 has_drm=0 audio=alsa backend profile=generic is_rgds=0
  local has_arm64_loader=0 has_armhf_loader=0 has_alsa=0 has_pulse=0 has_pipewire=0
  local drm_read=0 drm_write=0 mali_read=0 mali_write=0 fb_device="" fb_mode=""
  local active_width=0 active_height=0 gamepad_events="" touch_nodes="" drm_inventory=""
  local touch_count=0 portmaster_mapping=0
  local probe_root="${MCPE_PROBE_ROOT:-}"
  arch="${MCPE_TEST_ARCH:-$(uname -m 2>/dev/null || echo unknown)}"
  mem="$(mcpe_meminfo_kb "$probe_root/proc/meminfo" || echo 0)"
  model="$(tr -d '\000' <"$probe_root/proc/device-tree/model" 2>/dev/null || true)"
  compatible="$(tr '\000' ',' <"$probe_root/proc/device-tree/compatible" 2>/dev/null || true)"
  os_name="${CFW_NAME:-}"
  [ -n "$os_name" ] || os_name="$(sed -n 's/^OS_NAME=//p' "$probe_root/etc/os-release" 2>/dev/null | head -1 | sed 's/^"//;s/"$//')"
  [ -n "$os_name" ] || os_name="$(sed -n 's/^NAME=//p' "$probe_root/etc/os-release" 2>/dev/null | head -1 | sed 's/^"//;s/"$//')"
  [ -n "$os_name" ] || os_name=unknown
  mcpe_resolve_cfw
  if [ -n "${MCPE_TEST_COMPOSITOR:-}" ]; then compositor="$MCPE_TEST_COMPOSITOR"
  elif pidof sway >/dev/null 2>&1; then compositor=sway
  else compositor="${WAYLAND_DISPLAY:+wayland}"
  fi
  [ -n "$compositor" ] || { [ -n "${DISPLAY:-}" ] && compositor=x11 || compositor=none; }
  # A card node on its own is not evidence of DRM. PortMaster's westonwrap
  # mknods /dev/dri/card0 on firmwares that have none -- measured on muOS,
  # where it survives until reboot and /sys/class/drm stays empty -- so require
  # the kernel to list the card as well. Measured both ways: that muOS device
  # answers 0 with the synthetic node present, and an RG DS on ROCKNIX with a
  # real card0 and two DSI connectors still answers 1.
  ls "$probe_root"/dev/dri/card* >/dev/null 2>&1 &&
    ls "$probe_root"/sys/class/drm/card* >/dev/null 2>&1 && has_drm=1
  { [ -e "$probe_root/dev/mali" ] || [ -e "$probe_root/dev/mali0" ] || ls "$probe_root"/usr/lib*/libmali*.so* >/dev/null 2>&1; } && has_mali=1
  { ls "$probe_root"/usr/lib*/dri/*_dri.so >/dev/null 2>&1 || ls "$probe_root"/usr/lib*/libEGL_mesa.so* >/dev/null 2>&1; } && has_mesa=1
  { [ -e "$probe_root/lib/ld-linux-aarch64.so.1" ] || [ -e "$probe_root/usr/lib/ld-linux-aarch64.so.1" ] || [ "$arch" = aarch64 ]; } && has_arm64_loader=1
  { [ -e "$probe_root/lib/ld-linux-armhf.so.3" ] || [ -e "$probe_root/usr/lib32/ld-linux-armhf.so.3" ] || [ -e "$probe_root/usr/arm-linux-gnueabihf/lib/ld-linux-armhf.so.3" ]; } && has_armhf_loader=1
  [ -r "$probe_root/dev/dri/card0" ] && drm_read=1
  [ -w "$probe_root/dev/dri/card0" ] && drm_write=1
  [ -r "$probe_root/dev/mali" ] || [ -r "$probe_root/dev/mali0" ] && mali_read=1
  [ -w "$probe_root/dev/mali" ] || [ -w "$probe_root/dev/mali0" ] && mali_write=1
  drm_pair="$(mcpe_first_drm_mode 2>/dev/null || true)"
  connector="${drm_pair%%|*}"; mode="${drm_pair#*|}"
  [ "$drm_pair" = "$mode" ] && { connector=""; mode=""; }

  drm_inventory="$(mcpe_drm_inventory)"
  if [ -e "$probe_root/dev/fb0" ] || [ -d "$probe_root/sys/class/graphics/fb0" ]; then
    fb_device=/dev/fb0
    if [ -n "${MCPE_TEST_FB_MODE:-}" ]; then
      fb_mode="$MCPE_TEST_FB_MODE"
    elif [ -z "$probe_root" ] && command -v fbset >/dev/null 2>&1; then
      # virtual_size includes all scanout buffers on H700 (720x960 for a
      # physical 720x480 panel). fbset's first two geometry fields are the
      # visible dimensions; the following two are the virtual dimensions.
      fb_mode="$(fbset -s 2>/dev/null | awk '$1 == "geometry" { print $2 "x" $3; exit }')"
    fi
    [ -n "$fb_mode" ] || fb_mode="$(cat "$probe_root/sys/class/graphics/fb0/virtual_size" 2>/dev/null | tr ',' 'x')"
  fi
  [ -e "$probe_root/dev/snd" ] || [ -d "$probe_root/dev/snd" ] && has_alsa=1
  mcpe_probe_tool pactl && has_pulse=1
  { mcpe_probe_daemon pipewire || mcpe_probe_socket "${XDG_RUNTIME_DIR:-/nonexistent}/pipewire-0" ||
    mcpe_probe_socket /run/pipewire-0 || mcpe_probe_socket /run/pipewire/pipewire-0; } && has_pipewire=1
  if [ -n "${MCPE_TEST_AUDIO:-}" ]; then audio="$MCPE_TEST_AUDIO"
  elif mcpe_probe_tool pactl &&
       { [ -n "${MCPE_PROBE_ROOT:-}" ] || mcpe_bounded_probe 2 pactl info; }; then audio=pulse
  elif mcpe_probe_daemon pipewire-pulse; then audio=pulse
  elif mcpe_probe_daemon pipewire || mcpe_probe_socket "${XDG_RUNTIME_DIR:-/nonexistent}/pipewire-0" ||
       mcpe_probe_socket /run/pipewire-0 || mcpe_probe_socket /run/pipewire/pipewire-0; then audio=pipewire
  fi

  gamepad_events="$(grep -E 'H: Handlers=.*(js[0-9]+|event[0-9]+)' "$probe_root/proc/bus/input/devices" 2>/dev/null | sed -n 's/.*Handlers=//p' | tr '\n' ';' || true)"
  for node in "$probe_root"/sys/class/input/event*; do
    [ -r "$node/device/name" ] || continue
    grep -Eqi 'touch|goodix' "$node/device/name" || continue
    touch_nodes="${touch_nodes}/dev/input/$(basename "$node");"
    touch_count=$((touch_count + 1))
  done
  [ -n "${sdl_controllerconfig:-}" ] && portmaster_mapping=1

  case "$(printf '%s %s' "$model" "$compatible" | tr '[:upper:]' '[:lower:]')" in
    *"rg ds"*|*anbernic*rgds*) is_rgds=1; profile=rgds ;;
    *h700*|*sun50iw9*) profile=h700 ;;
    *r36s*|*rk3326*) profile=rk3326 ;;
  esac
  # RGDS fallback: RK3568 plus two connected DSI panels.
  if [ "$is_rgds" = 0 ] && printf '%s' "$compatible" | grep -qi rk3568; then
    [ "$(grep -l '^connected$' "$probe_root"/sys/class/drm/card*-DSI-*/status 2>/dev/null | wc -l)" -ge 2 ] && { is_rgds=1; profile=rgds; }
  fi

  if [ -n "${MCPE_GRAPHICS_BACKEND:-}" ]; then backend="$MCPE_GRAPHICS_BACKEND"
  elif [ "$compositor" = sway ] || [ "$compositor" = wayland ]; then backend=wayland
  elif [ "$has_mali" = 1 ] && [ -e "$probe_root/dev/disp" ]; then backend=mali
  elif [ "$has_drm" = 1 ]; then backend=kmsdrm
  elif [ "$compositor" = x11 ]; then backend=x11
  else backend=none
  fi

  if [ -n "$mode" ]; then
    active_width="${mode%x*}"; active_height="${mode#*x}"
  elif [ -n "$fb_mode" ]; then
    active_width="${fb_mode%x*}"; active_height="${fb_mode#*x}"
  elif [ -n "${DISPLAY_WIDTH:-}" ] && [ -n "${DISPLAY_HEIGHT:-}" ]; then
    active_width="$DISPLAY_WIDTH"; active_height="$DISPLAY_HEIGHT"
  fi

  mkdir -p "$(dirname "$out")"
  {
    printf 'MCPE_HOST_ARCH=%q\n' "$arch"
    printf 'MCPE_HOST_MODEL=%q\n' "$model"
    printf 'MCPE_HOST_COMPATIBLE=%q\n' "$compatible"
    printf 'MCPE_HOST_OS=%q\n' "$os_name"
    printf 'MCPE_CFW=%q\n' "$MCPE_CFW"
    printf 'MCPE_CFW_CONFIDENCE=%q\n' "$MCPE_CFW_CONFIDENCE"
    printf 'MCPE_HOST_MEMORY_KB=%q\n' "$mem"
    printf 'MCPE_HAS_ARM64_LOADER=%q\n' "$has_arm64_loader"
    printf 'MCPE_HAS_ARMHF_LOADER=%q\n' "$has_armhf_loader"
    printf 'MCPE_HOST_PROFILE=%q\n' "$profile"
    printf 'MCPE_HOST_COMPOSITOR=%q\n' "$compositor"
    printf 'MCPE_GRAPHICS_BACKEND_RESOLVED=%q\n' "$backend"
    printf 'MCPE_AUDIO_BACKEND_RESOLVED=%q\n' "$audio"
    printf 'MCPE_DRM_CONNECTOR=%q\n' "$connector"
    printf 'MCPE_DRM_MODE=%q\n' "$mode"
    printf 'MCPE_DRM_INVENTORY=%q\n' "$drm_inventory"
    printf 'MCPE_DRM_READABLE=%q\n' "$drm_read"
    printf 'MCPE_DRM_WRITABLE=%q\n' "$drm_write"
    printf 'MCPE_FB_DEVICE=%q\n' "$fb_device"
    printf 'MCPE_FB_MODE=%q\n' "$fb_mode"
    printf 'MCPE_ACTIVE_WIDTH=%q\n' "$active_width"
    printf 'MCPE_ACTIVE_HEIGHT=%q\n' "$active_height"
    printf 'MCPE_HAS_DRM=%q\n' "$has_drm"
    printf 'MCPE_HAS_MALI=%q\n' "$has_mali"
    printf 'MCPE_HAS_MESA=%q\n' "$has_mesa"
    printf 'MCPE_MALI_READABLE=%q\n' "$mali_read"
    printf 'MCPE_MALI_WRITABLE=%q\n' "$mali_write"
    printf 'MCPE_HAS_ALSA=%q\n' "$has_alsa"
    printf 'MCPE_HAS_PULSE=%q\n' "$has_pulse"
    printf 'MCPE_HAS_PIPEWIRE=%q\n' "$has_pipewire"
    printf 'MCPE_PORTMASTER_MAPPING=%q\n' "$portmaster_mapping"
    printf 'MCPE_GAMEPAD_EVENTS=%q\n' "$gamepad_events"
    printf 'MCPE_IS_RGDS=%q\n' "$is_rgds"
    printf 'MCPE_TOUCH_COUNT=%q\n' "$touch_count"
    printf 'MCPE_TOUCH_NODES=%q\n' "$touch_nodes"
  } >"$out"
}

mcpe_apply_platform_profile() {
  local resolved="${1:-$GAMEDIR/config/resolved_host.env}"
  mcpe_probe_platform "$resolved" || return 1
  # shellcheck disable=SC1090
  source "$resolved"
  export MCPE_HOST_ARCH MCPE_HOST_PROFILE MCPE_HOST_COMPOSITOR
  export MCPE_GRAPHICS_BACKEND_RESOLVED MCPE_AUDIO_BACKEND_RESOLVED MCPE_IS_RGDS
  export MCPE_CFW MCPE_CFW_CONFIDENCE
  # Retained for payload scripts that still read it directly.
  MCPE_IS_MUOS=0
  [ "$MCPE_CFW" = muos ] && MCPE_IS_MUOS=1
  export MCPE_IS_MUOS
  case "$MCPE_GRAPHICS_BACKEND_RESOLVED" in
    wayland) export SDL_DRIVER_OVERRIDE=wayland; export MCPE_SDL_VIDEODRIVER=wayland ;;
    mali) export SDL_DRIVER_OVERRIDE=mali ;;
    kmsdrm) export MCPE_SDL_VIDEODRIVER=kmsdrm ;;
    x11) export SDL_DRIVER_OVERRIDE=x11 ;;
  esac
  if [ "${MCPE_ACTIVE_WIDTH:-0}" -gt 0 ] && [ "${MCPE_ACTIVE_HEIGHT:-0}" -gt 0 ]; then
    export MCPE_DISPLAY_WIDTH="$MCPE_ACTIVE_WIDTH"
    export MCPE_DISPLAY_HEIGHT="$MCPE_ACTIVE_HEIGHT"
  fi
  # Let Bedrock and the kernel schedule across every CPU. The old H700 profile
  # reported only two CPUs to the game, then confined its chunk/mesh workers to
  # cores 0-1 while reserving one core each for simulation and rendering. That
  # was an early workaround for RenderDragon stutter, but on the recommended
  # non-RenderDragon builds it delays both newly exposed block faces and new
  # chunks. The client still accepts the MCPE_PIN_* and MCPE_FAKE_NPROC
  # variables as explicit developer overrides for comparison runs; the port no
  # longer supplies them automatically.
}
