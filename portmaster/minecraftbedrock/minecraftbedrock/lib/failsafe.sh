#!/bin/bash
# The failsafe ladder: what each rung actually changes.
#
# The state machine lives in failsafe_state.py; this file is the part a
# maintainer reads to answer "what is safe mode 2 doing to my launch?".
#
#   0 tuned         the measured profile; nothing suppressed
#   1 conservative  keep the display and audio stack, drop every tuning knob
#   2 minimal       rung 1, plus change the stack itself and silence audio
#   3 diagnostic    do not start Minecraft; collect a report instead
#
# Rungs 1 and 2 deliberately override settings.cfg. Safe mode exists because
# the player's chosen profile did not start, so honouring it again would just
# reproduce the failure -- and every rung above 0 is announced on screen.
#
# Every knob used here is one this port already defines. Where a plausible
# fallback could not be verified against this tree it is left out rather than
# guessed at; see docs/FAILSAFES.md for what is still missing and why.

mcpe_failsafe_key() {
  printf '%s|%s|%s|%s\n' \
    "${MCPE_PORT_VERSION:-unknown}" \
    "${MCPE_CFW:-unknown}" \
    "${MCPE_BEDROCK_VERSION_NAME:-${MCVER_OVERRIDE:-unknown}}" \
    "${MCPE_ABI_OVERRIDE:-auto}"
}

mcpe_failsafe_plan() {
  local env_output
  env_output="$(python3 "$GAMEDIR/failsafe_state.py" plan "$GAMEDIR" \
    "$(mcpe_failsafe_key)" "${MCPE_STAGE_PREV:-}" "${MCPE_SAFE_MODE:-}" \
    "${MCPE_FAILSAFE_STARTUP_SECONDS:-120}" 2>&1)" || {
    # A ladder that cannot read its own state must not block the launch.
    echo "Failsafe state unavailable; launching with the tuned profile."
    echo "$env_output"
    export MCPE_FAILSAFE_RUNG=0 MCPE_FAILSAFE_RUNG_NAME=tuned
    export MCPE_FAILSAFE_REASON="state unavailable" MCPE_FAILSAFE_PINNED=0
    return 0
  }
  eval "$env_output"
  export MCPE_FAILSAFE_KEY MCPE_FAILSAFE_RUNG MCPE_FAILSAFE_RUNG_NAME
  export MCPE_FAILSAFE_FLOOR MCPE_FAILSAFE_STREAK MCPE_FAILSAFE_REASON
  export MCPE_FAILSAFE_PINNED MCPE_FAILSAFE_STARTUP_SECONDS
}

# Rung 1: stop tuning. Everything here is something this port switched on for
# performance; none of it is required for the game to run.
mcpe_failsafe_apply_conservative() {
  export MCPE_PERFORMANCE_MODE=0        # leave CPU/GPU governors alone
  export MCPE_PERFORMANCE_OPTIONS=0     # do not rewrite the game's options.txt
  export MCPE_PREWARM_GAMEPLAY_ASSETS=0
  export MCPE_DISABLE_AUTO_COMPACTION=0
  export MCPE_VSYNC=1
  export MCPE_MAX_FPS=30
  # Thread pinning and the faked CPU count are an H700 measurement, not a
  # requirement; on an untested device they are a way to deadlock a start.
  unset MCPE_PIN_RENDER_CORE MCPE_PIN_MAIN_CORE MCPE_PIN_OTHER_CORES MCPE_FAKE_NPROC
  # Old builds crash during startup when they believe the network is up. The
  # in-client guard only covers arm64 1.16.221.01, so this is the general form.
  export MCPE_FAKE_NO_NETWORK=1
}

# Rung 2: change the stack. Each override below is a documented alternative
# path in this port, not a new one invented for safe mode.
mcpe_failsafe_apply_minimal() {
  mcpe_failsafe_apply_conservative
  export MCPE_MAX_FPS=20
  # 64-bit EGLUT path: drop the capability-chosen SDL driver back to the
  # script's own default, and stop handing the Crusty shim an explicit EGL
  # context. Both are the fallbacks run_bedrock.sh documents for devices whose
  # libmali/DRM behaviour does not match the probe.
  export SDL_DRIVER_OVERRIDE=x11
  export GAMEWINDOW_EGLUT_CRUSTY_CONTEXT=0
  # Audio off. On muOS the device is held exclusively by PipeWire and on dArkOS
  # the PipeWire client config is missing entirely, so a failing audio open is
  # a plausible cause of a start that never completes. Silence localises that.
  export MCPE_ALSOFT_DRIVERS=null
  export MCPE_SDL_AUDIODRIVER=dummy
  # The 32-bit path picks its video driver from the live sway/DRM state and
  # already falls back on its own; forcing a driver there would override a
  # correct choice with a guess, so it is deliberately left alone.
}

mcpe_failsafe_apply() {
  case "${MCPE_FAILSAFE_RUNG:-0}" in
    1) mcpe_failsafe_apply_conservative ;;
    2) mcpe_failsafe_apply_minimal ;;
    3) mcpe_failsafe_apply_minimal ;;
  esac
  export MCPE_FAILSAFE_RUNG
}

# One line per rung, for the log, the boot report and the on-screen notice.
mcpe_failsafe_describe() {
  case "${MCPE_FAILSAFE_RUNG:-0}" in
    0) printf 'tuned profile\n' ;;
    1) printf 'no CPU/GPU tuning, VSync on, 30 fps, offline mode\n' ;;
    2) printf 'rung 1 plus X11 video, no Crusty context hand-off, sound off, 20 fps\n' ;;
    3) printf 'diagnostic only; Minecraft is not started\n' ;;
  esac
}

mcpe_failsafe_record() { # exit_status duration_seconds
  local status="$1" duration="$2" env_output
  env_output="$(python3 "$GAMEDIR/failsafe_state.py" record "$GAMEDIR" \
    "$(mcpe_failsafe_key)" "${MCPE_FAILSAFE_RUNG:-0}" "$status" "$duration" \
    "${MCPE_FAILSAFE_STARTUP_SECONDS:-120}" 2>&1)" || {
    echo "Failsafe state could not be updated: $env_output"
    return 0
  }
  eval "$env_output"
  export MCPE_FAILSAFE_OUTCOME MCPE_FAILSAFE_NEXT_RUNG
}
