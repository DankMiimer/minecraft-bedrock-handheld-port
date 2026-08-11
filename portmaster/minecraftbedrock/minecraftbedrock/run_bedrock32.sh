#!/bin/bash
# Launch the 32-bit (armhf) mcpelauncher client directly on KMS/DRM.
# This is the R36S-class path (RK3326/RK3566 with a real /dev/dri): the armhf
# client statically links SDL3 with a kmsdrm driver, so no Weston/crusty stack
# is needed. Launch recipe from ImpressiveStay's R36S mcpe_launcher port
# (network jail removed there = working LAN), merged with this port's
# profile layout, performance mode, and asset prewarm.
set -u
GAMEDIR="${GAMEDIR:?run via 'Minecraft Bedrock.sh'}"
MCVER="${MCVER_OVERRIDE:?no version selected}"
DATA_ROOT="${MCPE_DATA_ROOT_OVERRIDE:-$GAMEDIR/profiles/default}"
DATA_DIR="$DATA_ROOT/mcpelauncher"
BIN="$GAMEDIR/bin32/mcpelauncher-client"
LOG="$GAMEDIR/weston_launch.log"
ESUDO="${ESUDO:-}"

[ -f "$GAMEDIR/versions/$MCVER/lib/armeabi-v7a/libminecraftpe.so" ] || {
  echo "version $MCVER has no 32-bit (armeabi-v7a) libraries"
  exit 1
}

# --- Frontend handling (mirrors weston_launch.sh) ----------------------------
# ROCKNIX-family launches ports with the display released, nothing to stop.
# Batocera-family (Knulli) ES and the muOS frontend hold fb/input nodes.
ES_INIT=/etc/init.d/S31emulationstation
ES_WAS_RUNNING=0
MUOS_FRONTEND_STOPPED=0
is_muos() {
  local cfw_lower
  [ "${MCPE_IS_MUOS:-0}" = 1 ] && return 0
  cfw_lower="$(printf '%s' "${CFW_NAME:-}" | tr '[:upper:]' '[:lower:]')"
  case "$cfw_lower" in *muos*) return 0 ;; esac
  [ -d /opt/muos ] || [ -d /mnt/mmc/MUOS ] || [ -d /mnt/sdcard/MUOS ]
}
stop_frontend() {
  if is_muos; then
    if pidof frontend.sh >/dev/null 2>&1 || pidof muxlaunch >/dev/null 2>&1; then
      MUOS_FRONTEND_STOPPED=1
      $ESUDO killall -q frontend.sh muxlaunch 2>/dev/null || true
      sleep 1
    fi
    return
  fi
  pidof sway >/dev/null 2>&1 && return
  [ -x "$ES_INIT" ] || return
  pidof emulationstation >/dev/null 2>&1 || return
  ES_WAS_RUNNING=1
  $ESUDO "$ES_INIT" stop
}
start_frontend() {
  if [ "$MUOS_FRONTEND_STOPPED" = 1 ]; then
    if [ -x /opt/muos/script/mux/frontend.sh ]; then
      setsid /opt/muos/script/mux/frontend.sh launcher </dev/null >/dev/null 2>&1 &
    fi
    MUOS_FRONTEND_STOPPED=0
    return
  fi
  [ "$ES_WAS_RUNNING" = 1 ] || return
  setsid $ESUDO "$ES_INIT" start </dev/null >/dev/null 2>&1
  ES_WAS_RUNNING=0
}

# --- Performance mode (restored on exit) --------------------------------------
CPU_POLICY_PATHS=()
CPU_POLICY_GOVERNORS=()
GPU_DEVFREQ_PATHS=()
GPU_DEVFREQ_GOVERNORS=()
PERFORMANCE_ACTIVE=0
enable_performance_mode() {
  [ "${MCPE_PERFORMANCE_MODE:-1}" = 1 ] || return
  local policy devfreq old_governor
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -r "$policy/scaling_governor" ] || continue
    old_governor="$(cat "$policy/scaling_governor")"
    CPU_POLICY_PATHS+=("$policy")
    CPU_POLICY_GOVERNORS+=("$old_governor")
    if grep -qw performance "$policy/scaling_available_governors" 2>/dev/null; then
      echo performance >"$policy/scaling_governor" 2>/dev/null || true
    fi
  done
  for devfreq in /sys/class/devfreq/*gpu*; do
    [ -r "$devfreq/governor" ] || continue
    old_governor="$(cat "$devfreq/governor")"
    GPU_DEVFREQ_PATHS+=("$devfreq")
    GPU_DEVFREQ_GOVERNORS+=("$old_governor")
    [ -w "$devfreq/governor" ] &&
      echo performance >"$devfreq/governor" 2>/dev/null || true
  done
  PERFORMANCE_ACTIVE=1
}
restore_performance_mode() {
  [ "$PERFORMANCE_ACTIVE" = 1 ] || return
  local i
  for ((i = 0; i < ${#CPU_POLICY_PATHS[@]}; i++)); do
    [ -w "${CPU_POLICY_PATHS[$i]}/scaling_governor" ] &&
      echo "${CPU_POLICY_GOVERNORS[$i]}" >"${CPU_POLICY_PATHS[$i]}/scaling_governor" 2>/dev/null || true
  done
  for ((i = 0; i < ${#GPU_DEVFREQ_PATHS[@]}; i++)); do
    [ -w "${GPU_DEVFREQ_PATHS[$i]}/governor" ] &&
      echo "${GPU_DEVFREQ_GOVERNORS[$i]}" >"${GPU_DEVFREQ_PATHS[$i]}/governor" 2>/dev/null || true
  done
  PERFORMANCE_ACTIVE=0
}

cleanup() {
  restore_performance_mode
  start_frontend
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Asset prewarm (page cache; removes first-use microSD stutter) ------------
if [ "${MCPE_PREWARM_GAMEPLAY_ASSETS:-1}" = 1 ] && [ -d "$GAMEDIR/versions/$MCVER/assets" ]; then
  find "$GAMEDIR/versions/$MCVER/assets" -type f \
    \( -path '*/resource_packs/vanilla/sounds/*' \
       -o -path '*/resource_packs/vanilla/particles/*' \) \
    -exec cat {} + >/dev/null 2>&1 || true
fi

stop_frontend
enable_performance_mode

# --- Environment (ImpressiveStay's working RK3326 recipe) ---------------------
export OPENSSL_armcap=0
export MALLOC_CHECK_=0
# Mesa knobs are inert on closed-blob devices, needed on Panfrost ones.
export MESA_GL_VERSION_OVERRIDE=2.0
export MESA_GLES_VERSION_OVERRIDE=2.0
export LIBGL_ES=2
export vblank_mode=0
export SDL_RENDER_VSYNC=0
export SDL_VIDEO_KMSDRM_DOUBLE_BUFFER=1
export MESA_GLSL_CACHE_DISABLE=0
export MESA_GLSL_CACHE_DIR="$GAMEDIR/.mesa_cache"
mkdir -p "$GAMEDIR/.mesa_cache"
export PAN_MESA_DEBUG=noaff,deqp
# 32-bit path targets <=1GB devices: give memory back to the OS aggressively.
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_TRIM_THRESHOLD_=131072
export SDL_JOYSTICK_HIDAPI=0
export SDL_JOYSTICK_DEADZONE=12000
export SDL_AUDIODRIVER="${MCPE_SDL_AUDIODRIVER:-alsa}"

# Display driver, per stack:
#  - sway compositor (ROCKNIX/Aurknix): the client renders as a Wayland
#    surface; sway owns /dev/dri, so kmsdrm would fail to get DRM master.
#  - otherwise (DarkOS RE and ArkOS-family: ES on fbdev/kmsdrm): the client
#    takes over kmsdrm directly.
SWAY_MODE=0
if [ "${MCPE_SDL_VIDEODRIVER:-}" = wayland ] || pidof sway >/dev/null 2>&1; then
  SWAY_MODE=1
fi
if [ -n "${MCPE_SDL_VIDEODRIVER:-}" ]; then
  export SDL_VIDEODRIVER="$MCPE_SDL_VIDEODRIVER"
elif [ "$SWAY_MODE" = 1 ]; then
  export SDL_VIDEODRIVER=wayland
else
  export SDL_VIDEODRIVER=kmsdrm
fi

if [ "$SDL_VIDEODRIVER" = kmsdrm ]; then
  DRM_CARD_INDEX=0
  case "${MCPE_DRM_CONNECTOR:-}" in card[0-9]-*) DRM_CARD_INDEX="${MCPE_DRM_CONNECTOR#card}"; DRM_CARD_INDEX="${DRM_CARD_INDEX%%-*}" ;; esac
  export SDL_VIDEO_KMSDRM_CARD_INDEX="$DRM_CARD_INDEX"
  export XDG_RUNTIME_DIR=/tmp/kmsdrm_runtime
  mkdir -p /tmp/kmsdrm_runtime
  chmod 700 /tmp/kmsdrm_runtime 2>/dev/null || true
else
  # Wayland: adopt sway's runtime env when launched outside the session (SSH).
  SWAY_PID="$(pidof sway 2>/dev/null | awk '{print $1}')"
  if [ -n "$SWAY_PID" ]; then
    [ -z "${XDG_RUNTIME_DIR:-}" ] &&
      export XDG_RUNTIME_DIR="$(tr '\0' '\n' </proc/$SWAY_PID/environ 2>/dev/null | sed -n 's/^XDG_RUNTIME_DIR=//p')"
    [ -z "${WAYLAND_DISPLAY:-}" ] &&
      export WAYLAND_DISPLAY="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]*$')"
    if [ -z "${SWAYSOCK:-}" ]; then
      SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)"
      [ -n "$SWAYSOCK" ] && export SWAYSOCK
    fi
  fi
fi

# Controller: the armhf client is an SDL app and honours the CFW's SDL mapping
# line, exported by the entry script from get_controls.
[ -n "${sdl_controllerconfig:-}" ] && export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

export LD_LIBRARY_PATH="$GAMEDIR/versions/$MCVER/lib/armeabi-v7a:$GAMEDIR/versions/$MCVER/lib/native/armeabi-v7a:$GAMEDIR/bin32/lib/armeabi-v7a:$GAMEDIR/lib32/armeabi-v7a:$GAMEDIR/lib32/armhf-system:/usr/lib/arm-linux-gnueabihf:/lib/arm-linux-gnueabihf:/usr/lib32:/lib32:/usr/lib:/lib"

# Data layout: same profile scheme as the 64-bit path, so a version's worlds
# and settings are identical regardless of which client ran it.
export XDG_DATA_HOME="$DATA_ROOT"
export MCPELAUNCHER_DATA_DIR="$DATA_DIR"
mkdir -p "$DATA_DIR/games/com.mojang"
# mcpelauncher hardcodes ~/.local/share/mcpelauncher in places.
mkdir -p "${HOME:-/root}/.local/share"
ln -sfn "$DATA_DIR" "${HOME:-/root}/.local/share/mcpelauncher"

SETTINGS="$DATA_DIR/mcpelauncher-client-settings.txt"
mkdir -p "$(dirname "$SETTINGS")"
touch "$SETTINGS"
grep -q "^audio_backend=" "$SETTINGS" 2>/dev/null ||
  echo "audio_backend=sdl3" >> "$SETTINGS"
# Only pin the UI scale when explicitly chosen (menu/env); the armhf client's
# own default is left alone otherwise.
if [ -n "${MCPE_UI_DENSITY_SCALE:-}" ]; then
  if grep -q "^scale=" "$SETTINGS" 2>/dev/null; then
    sed -i "s#^scale=.*#scale=$MCPE_UI_DENSITY_SCALE#" "$SETTINGS"
  else
    echo "scale=$MCPE_UI_DENSITY_SCALE" >> "$SETTINGS"
  fi
fi

# --- Game options ---------------------------------------------------------------
# Match the 64-bit launcher: explicit pins (menu settings / env) are always
# applied and added if missing; guardrails only edit keys the game already
# wrote and honour MCPE_PERFORMANCE_OPTIONS=0.
tune_game_options() {
  local games_root="$1" options_file
  options_file="$games_root/com.mojang/minecraftpe/options.txt"
  [ -f "$options_file" ] || { mkdir -p "$(dirname "$options_file")"; : > "$options_file"; }
  while IFS= read -r options_file; do
    [ -f "$options_file" ] || continue
    set_option() {
      grep -q "^$1:" "$options_file" && sed -i "s#^$1:.*#$1:$2#" "$options_file"
    }
    pin_option() {
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
    set_option gfx_multithreaded_renderer "${MCPE_MULTITHREADED_RENDERER:-1}"
    set_option dev_file_watcher 0
    set_option content_log_file 0
    set_option content_log_gui 0
  done < <(find "$games_root" -name options.txt 2>/dev/null)
}
tune_game_options "$DATA_ROOT/mcpelauncher/games"

chmod +x "$BIN" 2>/dev/null

# Optional gptokeyb overlay (hotkeys); the SDL client handles the pad itself.
if [ -n "${GPTOKEYB:-}" ]; then
  $GPTOKEYB "mcpelauncher-client" &
fi

# --- Panel mode detection (kmsdrm) --------------------------------------------
# SDL's kmsdrm backend picks the smallest DRM mode >= the requested window size.
# The client's built-in default is larger than these 4:3 handheld panels, so with
# no -ww/-wh SDL finds nothing and aborts with:
#   terminate called ... what(): Couldn't find any matching video modes
# (seen on R36S / dArkOS RE, 640x480). Read the connected connector's preferred
# (first) mode from sysfs and hand it to the client. Override: MCPE_WINDOW_SIZE=WxH.
detect_native_mode() {
  local c status mode
  for c in /sys/class/drm/card*-*; do
    [ -r "$c/status" ] && [ -r "$c/modes" ] || continue
    read -r status < "$c/status" 2>/dev/null || continue
    [ "$status" = connected ] || continue
    read -r mode < "$c/modes" 2>/dev/null || continue
    case "$mode" in
      [0-9]*x[0-9]*) printf '%s' "${mode%%[!0-9x]*}"; return 0 ;;
    esac
  done
  return 1
}

if [ "$SDL_VIDEODRIVER" = kmsdrm ]; then
  echo "--- DRM diagnostics ---"
  ls -1 /dev/dri 2>/dev/null | sed 's/^/  dev: /'
  for c in /sys/class/drm/card*-*; do
    [ -r "$c/status" ] || continue
    echo "  $(basename "$c"): status=$(cat "$c/status" 2>/dev/null) modes=[$(tr '\n' ' ' < "$c/modes" 2>/dev/null)]"
  done
  pidof emulationstation >/dev/null 2>&1 &&
    echo "  NOTE: emulationstation still running (may hold DRM master)"
  echo "-----------------------"

  NATIVE_MODE="${MCPE_WINDOW_SIZE:-$(detect_native_mode || true)}"
  if [ -n "$NATIVE_MODE" ]; then
    echo "Using panel mode: $NATIVE_MODE"
    ARGS="${ARGS:-} -ww ${NATIVE_MODE%%x*} -wh ${NATIVE_MODE##*x}"
  else
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
      echo "No connected DRM mode; falling back to the active Wayland session."
      export SDL_VIDEODRIVER=wayland
    else
      echo "ERROR: KMSDRM exposes no connected video mode."
      echo "Run $GAMEDIR/create_support_bundle.sh and attach the bundle to a device report."
      exit 1
    fi
  fi

  # --- GL stack diagnostics (armhf EGL/GLES) ----------------------------------
  # "Can't load EGL/GL library on window creation" = SDL could not dlopen a
  # 32-bit libEGL.so.1 / libGLESv2.so.2. Distinguish "missing" from "present but
  # broken deps", and auto-add a directory that has one but isn't searched.
  echo "--- GL diagnostics (armhf) ---"
  for d in /usr/lib/arm-linux-gnueabihf /lib/arm-linux-gnueabihf /usr/lib32 /lib32 \
           /usr/lib/arm-linux-gnueabihf/mali /usr/lib /usr/local/lib; do
    [ -d "$d" ] || continue
    hits="$(ls -1 "$d" 2>/dev/null | grep -E '^lib(EGL|GLESv2|gbm|mali|drm)' | tr '\n' ' ')"
    [ -n "$hits" ] && echo "  $d: $hits"
  done
  echo "  aarch64 side: $(ls -1 /usr/lib/aarch64-linux-gnu 2>/dev/null | grep -E '^lib(EGL|GLESv2|mali)' | tr '\n' ' ')"

  egl_found=""
  old_ifs="$IFS"; IFS=:
  for p in $LD_LIBRARY_PATH; do
    [ -n "$p" ] && [ -e "$p/libEGL.so.1" ] && { egl_found="$p"; break; }
  done
  IFS="$old_ifs"
  if [ -z "$egl_found" ]; then
    for d in /usr/lib/arm-linux-gnueabihf/mali /usr/lib32 /lib32 /usr/local/lib /usr/lib; do
      if [ -e "$d/libEGL.so.1" ]; then
        echo "  adding unsearched EGL dir to LD_LIBRARY_PATH: $d"
        export LD_LIBRARY_PATH="$d:$LD_LIBRARY_PATH"
        egl_found="$d"
        break
      fi
    done
  fi
  if [ -n "$egl_found" ]; then
    echo "  libEGL.so.1 resolves from: $egl_found"
    for so in libEGL.so.1 libGLESv2.so.2; do
      [ -e "$egl_found/$so" ] || { echo "  MISSING: $so"; continue; }
      if command -v ldd >/dev/null 2>&1; then
        miss="$(ldd "$egl_found/$so" 2>/dev/null | grep 'not found' | tr -s ' ' | tr '\n' ' ')"
        [ -n "$miss" ] && echo "  $so UNMET DEPS: $miss" || echo "  $so deps OK"
      fi
    done
  else
    echo "  WARNING: no 32-bit libEGL.so.1 found in any searched directory"
  fi

  # What do the system GL entry points actually resolve to (Mesa vs Mali blob)?
  for so in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
    for d in /usr/lib/arm-linux-gnueabihf /lib/arm-linux-gnueabihf; do
      [ -e "$d/$so" ] && { echo "  $so -> $(readlink -f "$d/$so" 2>/dev/null)"; break; }
    done
  done

  # Mali-blob devices (RK3326 / Mali G31) provide their own GBM *inside* the
  # blob. This port bundles a Mesa libgbm in lib32/armeabi-v7a which sits
  # earlier on LD_LIBRARY_PATH and shadows it. Mesa GBM cannot interoperate
  # with Mali EGL, and SDL then dies with:
  #   what(): Can't load EGL/GL library on window creation.
  # When a Mali GBM blob is present, let the system libs win over the bundled
  # Mesa ones (version/ and bin32/ keep priority) and point SDL at the blob.
  # Force the old behaviour with MCPE_GL_DRIVER=mesa.
  MALI_GBM=""
  for d in /usr/lib/arm-linux-gnueabihf /lib/arm-linux-gnueabihf; do
    for f in "$d"/libmali*gbm*.so; do
      [ -e "$f" ] && { MALI_GBM="$f"; break 2; }
    done
  done
  if [ -n "$MALI_GBM" ] && [ "${MCPE_GL_DRIVER:-auto}" != mesa ]; then
    echo "  Mali GBM blob found: $MALI_GBM"
    echo "  -> preferring system GL libs over bundled Mesa gbm"
    export LD_LIBRARY_PATH="$GAMEDIR/versions/$MCVER/lib/armeabi-v7a:$GAMEDIR/versions/$MCVER/lib/native/armeabi-v7a:$GAMEDIR/bin32/lib/armeabi-v7a:/usr/lib/arm-linux-gnueabihf:/lib/arm-linux-gnueabihf:$GAMEDIR/lib32/armeabi-v7a:$GAMEDIR/lib32/armhf-system:/usr/lib32:/lib32:/usr/lib:/lib"
    export SDL_VIDEO_EGL_DRIVER="$MALI_GBM"
    export SDL_VIDEO_GL_DRIVER="$MALI_GBM"
    echo "  SDL_VIDEO_EGL_DRIVER=$MALI_GBM"
  else
    echo "  no Mali GBM blob (or MCPE_GL_DRIVER=mesa): leaving GL setup as-is"
  fi
  echo "------------------------------"
fi

# --- Privilege -----------------------------------------------------------------
# The upstream R36S port (impressiveStay) runs the client as root, and on
# ArkOS-family CFWs that is the difference between working and not:
#   * KMS modesetting needs DRM master, which the unprivileged ES user does not
#     get while EmulationStation is still running;
#   * the Mali blob needs its device node (/dev/mali0), typically root-only.
# Note the upstream port also loses LD_LIBRARY_PATH here (its ESUDO is
# `sudo --preserve-env=<short list>`), so it never loads its own bundled Mesa
# libgbm and falls through to the system Mali GBM. Opt out: MCPE_RUN_AS_ROOT=0.
RUN_PREFIX=""
NEEDS_PRIVILEGE=0
[ "$SDL_VIDEODRIVER" = kmsdrm ] && [ ! -w "/dev/dri/card${SDL_VIDEO_KMSDRM_CARD_INDEX:-0}" ] && NEEDS_PRIVILEGE=1
[ -e /dev/mali0 ] && [ ! -r /dev/mali0 ] && NEEDS_PRIVILEGE=1
RUN_AS_ROOT="${MCPE_RUN_AS_ROOT:-auto}"
if { [ "$RUN_AS_ROOT" = 1 ] || { [ "$RUN_AS_ROOT" = auto ] && [ "$NEEDS_PRIVILEGE" = 1 ]; }; } && [ -n "${ESUDO:-}" ]; then
  RUN_PREFIX="$ESUDO env LD_LIBRARY_PATH=$LD_LIBRARY_PATH XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/kmsdrm_runtime} XDG_DATA_HOME=$XDG_DATA_HOME MCPELAUNCHER_DATA_DIR=$MCPELAUNCHER_DATA_DIR SDL_VIDEODRIVER=$SDL_VIDEODRIVER SDL_VIDEO_KMSDRM_CARD_INDEX=${SDL_VIDEO_KMSDRM_CARD_INDEX:-0} SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-alsa} SDL_VIDEO_KMSDRM_DOUBLE_BUFFER=${SDL_VIDEO_KMSDRM_DOUBLE_BUFFER:-1}"
  echo "Running client through scoped ESUDO (device permissions were not changed)"
else
  echo "Running client unprivileged"
fi

echo "=== launching 32-bit: version=$MCVER sdl=$SDL_VIDEODRIVER ==="
if [ "${MCPE_32BIT_TEE_LOG:-0}" = 1 ]; then
  $RUN_PREFIX "$BIN" -dg "$GAMEDIR/versions/$MCVER" ${ARGS:-} 2>&1 | tee "$LOG"
  status="${PIPESTATUS[0]}"
else
  $RUN_PREFIX "$BIN" -dg "$GAMEDIR/versions/$MCVER" ${ARGS:-} >"$LOG" 2>&1
  status="$?"
fi

[ -n "${GPTOKEYB:-}" ] && $ESUDO killall -9 gptokeyb 2>/dev/null
echo "--- exit: $status ---"
cleanup
exit "$status"
