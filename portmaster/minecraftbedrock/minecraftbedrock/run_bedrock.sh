#!/bin/bash
# Configure and run the EGLUT mcpelauncher client through the Weston/crusty
# stack. Derived from the RG34XX-SP production `_device_run_eglut.sh`.
GAMEDIR="${GAMEDIR:?run via 'Minecraft Bedrock.sh'}"
cd "$GAMEDIR" || exit 1
# shellcheck disable=SC1091
source "$GAMEDIR/lib/performance.sh" || {
  echo "Missing performance profile helpers."
  exit 1
}
source "$GAMEDIR/lib/abi.sh" || {
  echo "Missing architecture policy helpers."
  exit 1
}
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh" || {
  echo "Missing common runtime helpers."
  exit 1
}
# shellcheck disable=SC1091
source "$GAMEDIR/lib/audio.sh" || {
  echo "Missing audio backend helpers."
  exit 1
}

BIN64="$GAMEDIR/bin/mcpelauncher-client"
BIN32="$GAMEDIR/bin32/mcpelauncher-client"
# Repair only the two shipped clients when an older/DOS-origin unzip lost
# their executable bits.  Release archives also carry correct UNIX modes.
for MCPE_CLIENT_BIN in "$BIN64" "$BIN32"; do
  if [ -f "$MCPE_CLIENT_BIN" ] && [ ! -x "$MCPE_CLIENT_BIN" ]; then
    chmod u+x "$MCPE_CLIENT_BIN" 2>/dev/null || true
  fi
done
unset MCPE_CLIENT_BIN
export BIN_OVERRIDE="$BIN64"
export EXTRA_LIB="$GAMEDIR/libs.aarch64"
export MCVER_OVERRIDE="${MCVER_OVERRIDE:?no version selected}"
export MCPE_DATA_ROOT_OVERRIDE="${MCPE_DATA_ROOT_OVERRIDE:-$GAMEDIR/profiles/default}"

# --- Architecture (ABI) selection ---------------------------------------------
# The port ships two clients: bin/ (aarch64 EGLUT via Weston/crusty — Knulli
# H700, muOS, ROCKNIX) and bin32/ (armhf SDL3 direct-kmsdrm from the R36S
# port — RK3326-class devices with a real /dev/dri and armhf multilib). A
# version dir can carry either or both ABIs; pick per what is installed and
# what the device can run. The 64-bit client needs ~200 MB more RAM, so
# low-memory devices (R36S 512 MB) default to 32-bit when both are available.
V_HAS64=0 V_HAS32=0
[ -f "$GAMEDIR/versions/$MCVER_OVERRIDE/lib/arm64-v8a/libminecraftpe.so" ] && V_HAS64=1
[ -f "$GAMEDIR/versions/$MCVER_OVERRIDE/lib/armeabi-v7a/libminecraftpe.so" ] && V_HAS32=1
ARM64_USABLE=0
if [ -f "$BIN64" ] && mcpe_loader_present arm64; then
  ARM64_USABLE=1
fi
ARMHF_USABLE=0
if [ -f "$BIN32" ] && mcpe_loader_present armhf && [ -e /dev/dri/card0 ]; then
  ARMHF_USABLE=1
fi
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
ABI="${MCPE_ABI_OVERRIDE:-}"
case "$ABI" in
  "") ;;
  armhf|arm32|armv7|armeabi-v7a|32) ABI=armhf ;;
  arm64|aarch64|arm64-v8a|64) ABI=arm64 ;;
  *)
    echo "ERROR: unknown MCPE_ABI_OVERRIDE '$ABI' (use armhf or arm64)."
    exit 1
    ;;
esac
if [ -z "$ABI" ]; then
  ABI="$(mcpe_choose_default_abi \
    "$V_HAS64" "$V_HAS32" "$ARM64_USABLE" "$ARMHF_USABLE" \
    "${MCPE_HOST_PROFILE:-generic}" \
    "${MCPE_GRAPHICS_BACKEND_RESOLVED:-unknown}" \
    "${MCPE_HOST_ARCH:-$(uname -m 2>/dev/null || echo unknown)}" "$MEM_KB")"
fi
if [ "$ABI" = arm64 ] && [ "$V_HAS64" = 0 ]; then
  echo "ERROR: version $MCVER_OVERRIDE has no 64-bit (arm64-v8a) libraries."
  [ "$V_HAS32" = 1 ] && echo "Install an arm64 APK or launch with MCPE_ABI_OVERRIDE=armhf on an armhf-capable R36S/RK3326 setup."
  exit 1
fi
if [ "$ABI" = armhf ] && [ "$V_HAS32" = 0 ]; then
  echo "ERROR: version $MCVER_OVERRIDE has no 32-bit (armeabi-v7a) libraries."
  [ "$V_HAS64" = 1 ] && echo "Install an armeabi-v7a APK or launch with MCPE_ABI_OVERRIDE=arm64 on an aarch64 setup."
  exit 1
fi
if [ "$ABI" = armhf ] && [ "$ARMHF_USABLE" = 0 ]; then
  if [ -z "${MCPE_ABI_OVERRIDE:-}" ] && [ "$V_HAS64" = 1 ] && [ "$ARM64_USABLE" = 1 ]; then
    echo "32-bit path unavailable on this device (needs /dev/dri + armhf multilib); using 64-bit"
    ABI=arm64
  else
    echo "ERROR: version $MCVER_OVERRIDE is 32-bit only, but this device cannot run"
    echo "the 32-bit client (needs a real /dev/dri and armhf multilib, e.g."
    echo "R36S/RK3326 dArkOS, Aurknix, DarkOS RE, or ArkOS-for-clone builds)."
    exit 1
  fi
fi
if [ "$ABI" = arm64 ] && [ "$ARM64_USABLE" = 0 ]; then
  if [ -z "${MCPE_ABI_OVERRIDE:-}" ] && [ "$V_HAS32" = 1 ] && [ "$ARMHF_USABLE" = 1 ]; then
    echo "64-bit path unavailable on this device; using 32-bit"
    ABI=armhf
  else
    echo "ERROR: version $MCVER_OVERRIDE needs the 64-bit client, but this device"
    echo "cannot run it (needs aarch64 userspace/loader). Install an armeabi-v7a"
    echo "APK for R36S/RK3326-class 32-bit systems."
    exit 1
  fi
fi
echo "ABI: $ABI (version has: 64=$V_HAS64 32=$V_HAS32, usable: 64=$ARM64_USABLE 32=$ARMHF_USABLE, mem=${MEM_KB}kB)"
mcpe_stage abi
mcpe_report_set abi "$ABI (installed: 64=$V_HAS64 32=$V_HAS32; usable: 64=$ARM64_USABLE 32=$ARMHF_USABLE; override=${MCPE_ABI_OVERRIDE:-none})"
if [ "$ABI" = armhf ]; then
  mcpe_apply_r36s_defaults "$ABI"
  echo "R36S performance preset: ${MCPE_MAX_FPS} fps, render request ${MCPE_RENDER_DISTANCE} blocks, VSync ${MCPE_VSYNC}"
  export PORT_32BIT=Y
else
  mcpe_apply_arm64_defaults "$ABI"
  echo "Arm64 handheld preset: ${MCPE_MAX_FPS} fps, render distance ${MCPE_RENDER_DISTANCE} blocks, VSync ${MCPE_VSYNC}, UI scale ${MCPE_UI_DENSITY_SCALE}"
fi
if command -v pm_platform_helper >/dev/null 2>&1; then
  if [ "$ABI" = armhf ]; then
    pm_platform_helper "$BIN32" || true
  else
    pm_platform_helper "$BIN64" || true
  fi
fi
if [ "$ABI" = armhf ]; then
  exec bash "$GAMEDIR/run_bedrock32.sh"
fi

# The 32-bit Sway path can keep the launcher's fullscreen handoff surface up
# until Minecraft maps. Other display stacks must release it before taking
# over their own compositor/framebuffer.
if [ -n "${MCPE_MENU_HANDOFF_PID:-}" ]; then
  kill "$MCPE_MENU_HANDOFF_PID" 2>/dev/null || true
  unset MCPE_MENU_HANDOFF_PID
fi

# --- Weston runtime (weston_pkg_0.2) — 64-bit EGLUT path only -----------------
# Resolved here (not in the entry script) so a 32-bit-only install never needs
# it. weston_launch.sh requires WESTON_SQUASH.
if [ -z "${WESTON_SQUASH:-}" ]; then
  WESTON_SQUASH="$(bash "$GAMEDIR/ensure_runtime.sh" weston_pkg_0.2.aarch64)" || {
    echo "Could not obtain a checksum-verified Weston runtime."
    echo "Run create_support_bundle.sh and include the resulting archive in a report."
    exit 1
  }
  export WESTON_SQUASH
fi
mcpe_stage runtime
mcpe_report_set weston_runtime "$WESTON_SQUASH"

# Backing SDL video driver for crusty, per display stack:
#  - sway compositor (ROCKNIX): crusty nests under sway -> wayland
#  - Allwinner fbdev+/dev/disp (Knulli H700): the blob's fbdev driver -> mali
#  - otherwise: x11
if [ -z "${SDL_DRIVER_OVERRIDE:-}" ]; then
  if pidof sway >/dev/null 2>&1; then
    SDL_DRIVER_OVERRIDE=wayland
  elif [ -e /dev/disp ] ||
       { [ "${MCPE_IS_MUOS:-0}" = 1 ] && { [ -e /dev/mali ] || [ -e /dev/mali0 ]; }; }; then
    SDL_DRIVER_OVERRIDE=mali
  else
    SDL_DRIVER_OVERRIDE=x11
  fi
fi
export SDL_DRIVER_OVERRIDE

# The Westonpack Crusty EGL shim requires an explicit context hand-off on
# libmali/no-DRM devices. A versioned preload module records the SDL handles
# through exported calls; neither the client nor module reads private offsets.
export GAMEWINDOW_EGLUT_CRUSTY_CONTEXT="${GAMEWINDOW_EGLUT_CRUSTY_CONTEXT:-1}"
# Crusty's direct Mali window has no real X11 FocusIn event; force focus so
# linux-gamepad polls the pad.
export GAMEWINDOW_EGLUT_FORCE_FOCUS="${GAMEWINDOW_EGLUT_FORCE_FOCUS:-1}"

export MCPE_REPORTED_DISPLAY_SCALE="${MCPE_REPORTED_DISPLAY_SCALE:-1}"
export MCPE_DISABLE_AUTO_COMPACTION="${MCPE_DISABLE_AUTO_COMPACTION:-0}"

# Thread layout measured on a 4x Cortex-A53 (H700): render thread on core 3,
# simulation ("MINECRAFT MAIN") on core 2, chunk workers on 0-1, and the game
# sees 2 CPUs so its worker pools fit. Cut stutters ~4x. Only applied on
# 4-core devices; elsewhere the engine keeps its defaults.
# busybox systems (ROCKNIX) have no nproc.
NCORES="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)"
# Affinity is set by the validated H700 profile in lib/platform.sh. Core count
# alone is not a device identifier (RK356x is also commonly four-core).
export MCPE_AFFINITY_LOG="${MCPE_AFFINITY_LOG:-0}"

chmod +x "$BIN_OVERRIDE" 2>/dev/null

# Audio: the launcher's own pulseaudio backend is the default and works on
# Knulli and ROCKNIX (pipewire-pulse). Optionally, a HOST (glibc aarch64)
# FMOD Engine library obtained from fmod.com can be dropped at
# $GAMEDIR/fmod/libfmod.so.12.0 — the launcher then uses real FMOD (looked
# up via $XDG_DATA_HOME/mcpelauncher/lib/native/<abi>/). The game's own
# Android libfmod.so does NOT work here (bionic, not glibc).
FMOD_HOST="$GAMEDIR/fmod/libfmod.so.12.0"
FMOD_DST="$MCPE_DATA_ROOT_OVERRIDE/mcpelauncher/lib/native/arm64-v8a/libfmod.so.12.0"
if [ -f "$FMOD_HOST" ]; then
  mkdir -p "$(dirname "$FMOD_DST")" 2>/dev/null
  cp -f "$FMOD_HOST" "$FMOD_DST" 2>/dev/null
else
  rm -f "$FMOD_DST" 2>/dev/null
fi

# Audio output backend: see lib/audio.sh. Shared with the 32-bit path,
# which previously had no triage at all.
mcpe_resolve_audio

# --- Launcher settings + controller mapping ----------------------------------
SETTINGS="$MCPE_DATA_ROOT_OVERRIDE/mcpelauncher/mcpelauncher-client-settings.txt"
mkdir -p "$(dirname "$SETTINGS")"
touch "$SETTINGS"

# game-window's EGLUT backend does not consume SDL_GAMECONTROLLERCONFIG; it
# reads gamecontrollerdb.txt from the launcher data dir, and its evdev button
# indices differ from SDL's. Mapping lines are matched by controller GUID, so
# all known-device lines are concatenated and the right one is picked at
# runtime. Contribute new lines in controls/ (see controls/README.md).
GAMEPAD_DB="$(dirname "$SETTINGS")/gamecontrollerdb.txt"
: > "$GAMEPAD_DB"
for controller_map in "$GAMEDIR/controls/"*.gamecontrollerdb.txt; do
  [ -f "$controller_map" ] || continue
  case "$controller_map" in *.sdl.gamecontrollerdb.txt) continue ;; esac
  cat "$controller_map" >>"$GAMEPAD_DB"
done

# Unknown pad? Auto-generate a standard-layout mapping line for any connected
# gamepad whose GUID is not covered above (genmap.py replicates the backend's
# button numbering). Users on untested devices get working default controls;
# the generated line is logged so it can be contributed back.
if command -v python3 >/dev/null 2>&1; then
  KNOWN_GUIDS="$(cut -d, -f1 "$GAMEPAD_DB" 2>/dev/null | tr '\n' ' ')"
  GENERATED="$(python3 "$GAMEDIR/genmap.py" $KNOWN_GUIDS 2>/dev/null)"
  if [ -n "$GENERATED" ]; then
    echo "Auto-generated controller mapping (please report/contribute):"
    echo "$GENERATED"
    echo "$GENERATED" >> "$GAMEPAD_DB"
  fi
fi

set_kv() {
  if grep -q "^$1=" "$SETTINGS" 2>/dev/null; then
    sed -i "s#^$1=.*#$1=$2#" "$SETTINGS"
  else
    echo "$1=$2" >> "$SETTINGS"
  fi
}
set_kv enable_imgui "${IMGUI:-false}"   # imgui's GL loader crashes on this path
set_kv scale "${MCPE_UI_DENSITY_SCALE:-2}"

# --- Game options ---------------------------------------------------------------
# Two tiers: explicit pins (menu settings / env: render distance, FPS cap,
# vsync) are always applied and added if missing — this is how the render
# distance can go below the in-game slider's minimum. The guardrails
# (renderer flag, dev logging) only edit keys the game already wrote and can
# be turned off with MCPE_PERFORMANCE_OPTIONS=0 without losing the pins.
tune_game_options() {
  local games_root="$1" options_file
  # Seed the profile's options file so pins apply from the very first launch.
  options_file="$games_root/com.mojang/minecraftpe/options.txt"
  [ -f "$options_file" ] || { mkdir -p "$(dirname "$options_file")"; : > "$options_file"; }
  while IFS= read -r options_file; do
    [ -f "$options_file" ] || continue
    set_option() { # guardrail: edit only when the key exists
      grep -q "^$1:" "$options_file" && sed -i "s#^$1:.*#$1:$2#" "$options_file"
    }
    pin_option() { # explicit choice: add the key when missing
      if grep -q "^$1:" "$options_file"; then
        sed -i "s#^$1:.*#$1:$2#" "$options_file"
      else
        echo "$1:$2" >> "$options_file"
      fi
    }
    [ -n "${MCPE_RENDER_DISTANCE:-}" ] && pin_option gfx_viewdistance "$MCPE_RENDER_DISTANCE"
    [ -n "${MCPE_MAX_FPS:-}" ] && pin_option gfx_max_framerate "$MCPE_MAX_FPS"
    [ -n "${MCPE_VSYNC:-}" ] && pin_option gfx_vsync "$MCPE_VSYNC"
    [ "${MCPE_PERFORMANCE_OPTIONS:-1}" = 1 ] || continue
    if [ "${MCPE_ARM64_HANDHELD_PRESET:-0}" = 1 ]; then
      mcpe_apply_arm64_game_options "$options_file" \
        "$GAMEDIR/defaults/arm64-handheld-options.txt" || {
          echo "Could not apply arm64 handheld game defaults: $options_file" >&2
          return 1
        }
    fi
    # Multithreaded renderer OFF does not submit static chunk draws on this
    # EGLUT/crusty/libmali stack — keep it ON.
    set_option gfx_multithreaded_renderer "${MCPE_MULTITHREADED_RENDERER:-1}"
    set_option dev_file_watcher 0
    set_option content_log_file 0
    set_option content_log_gui 0
  done < <(find "$games_root" -name options.txt 2>/dev/null)
}
tune_game_options "$MCPE_DATA_ROOT_OVERRIDE/mcpelauncher/games"

export APP_EXTRA_ARGS="${ARGS:-}"
GFX="${GFX:-crusty_x11egl}"
TMO="${TMO:-0}"

# Opt-in FPS measurement: MCPE_MEASURE_FPS=1 records a frame trace and prints
# a summary on exit. No overhead unless enabled.
FPS_TRACE=""
if [ "${MCPE_MEASURE_FPS:-0}" = 1 ]; then
  FPS_TRACE="$GAMEDIR/fps-trace-$(date +%H%M%S).csv"
  export MCPE_FRAME_METRICS="$FPS_TRACE"
fi

echo "=== launching: version=$MCVER_OVERRIDE gfx=$GFX cores=$NCORES ==="
# A breadcrumb left on `client-exec` means the client was started and never
# came back: the shape of the RG35XX-H/Knulli hang in issue #2.
mcpe_stage client-exec
mcpe_report_set launch "gfx=$GFX sdl_video=${SDL_DRIVER_OVERRIDE:-unset} sdl_audio=${MCPE_SDL_AUDIODRIVER:-openal} alsoft=${ALSOFT_DRIVERS:-default} cores=$NCORES timeout=$TMO"
mcpe_report_print
if [ "${MCPE_EDITION_ID:-minecraftbedrock.standard}" = minecraftbedrock.rgds ]; then
  [ -f "$GAMEDIR/rgds/rgds_session.sh" ] || { echo "RGDS session helper is missing."; exit 1; }
  # shellcheck disable=SC1090
  source "$GAMEDIR/rgds/rgds_session.sh"
  mcpe_rgds_start || exit 1
fi
if [ "${MCPE_EDITION_ID:-minecraftbedrock.standard}" = minecraftbedrock.rgds ]; then
  bash "$GAMEDIR/weston_launch.sh" "$TMO" "$GFX" &
  RGDS_GAME_PID=$!
  export RGDS_GAME_PID
  wait "$RGDS_GAME_PID"
  GAME_STATUS=$?
  mcpe_rgds_stop
  trap - EXIT HUP INT TERM
else
  bash "$GAMEDIR/weston_launch.sh" "$TMO" "$GFX"
  GAME_STATUS=$?
fi

if [ -n "$FPS_TRACE" ] && [ -s "$FPS_TRACE" ]; then
  echo "=== FPS SUMMARY ($FPS_TRACE) ==="
  awk -F, 'NR>1 && $3+0>2000000 {  # skip first ~2s of load
             d=$3-p; if(p>0 && d>0){n++; s+=d; a[n]=d} p=$3
           }
           END{
             if(n<10){print "  not enough frames"; exit}
             asort(a);
             med=a[int(n/2)];
             fps=1000000/med;
             # percent of frames at >=58fps (<=17240us) and >=30fps
             for(i=1;i<=n;i++){ if(a[i]<=17240)c60++; if(a[i]<=33333)c30++ }
             printf "  frames=%d  median=%.1fms (%.1f fps)  mean=%.1ffps\n", n, med/1000, fps, 1000000/(s/n);
             printf "  %%>=58fps=%.0f%%  %%>=30fps=%.0f%%  p99frame=%.1fms\n", 100*c60/n, 100*c30/n, a[int(n*0.99)]/1000
           }' "$FPS_TRACE"
fi

exit "$GAME_STATUS"
