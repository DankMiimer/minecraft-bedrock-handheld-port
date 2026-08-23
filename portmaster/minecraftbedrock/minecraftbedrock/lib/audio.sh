#!/bin/bash
# Audio backend selection, shared by both launch paths.
#
# This lived inside run_bedrock.sh and so only ever ran for the 64-bit client.
# The 32-bit path set SDL_AUDIODRIVER=alsa and nothing else, which left
# ALSOFT_DRIVERS unset -- so OpenAL Soft walked its built-in preference list,
# tried PipeWire first, and on dArkOS RE (issue #1) produced:
#     [ALSOFT] (EE) Failed to create PipeWire event context (errno: 2)
#     [ALSOFT] (EE) Could not query RTKit: No such file or directory (2)
# because that image ships the PipeWire libraries without a client config.
#
# Three device families, in the order they are tested:
#  - Pulse-compatible server up (Knulli, ROCKNIX: pipewire-pulse) -- pin its
#    socket and prefer SDL3's native PulseAudio driver.
#  - PipeWire WITHOUT a pulse socket (muOS Jacaranda: PIPEWIRE_RUNTIME_DIR=/run)
#    -- raw ALSA fails with "Device or resource busy" because PipeWire holds
#    the device exclusively, so route through the PipeWire ALSA plugin.
#  - Bare ALSA (older minimal builds) -- force OpenAL Soft/SDL onto ALSA.
#
# MCPE_SDL_AUDIODRIVER is consumed by weston_launch.sh (64-bit) and by
# run_bedrock32.sh (32-bit). Overrides: MCPE_ALSOFT_DRIVERS, MCPE_SDL_AUDIODRIVER.

mcpe_find_pulse_socket() {
  local s
  for s in "${PULSE_RUNTIME_PATH:-/nonexistent}/native" \
           "${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null)}/pulse/native" \
           /run/user/*/pulse/native /run/*-runtime-dir/pulse/native \
           /run/pulse/native /var/run/pulse/native /tmp/pulse-*/native; do
    [ -S "$s" ] && { echo "$s"; return 0; }
  done
  return 1
}

mcpe_find_pipewire_socket() {
  local s
  for s in "${PIPEWIRE_RUNTIME_DIR:-/nonexistent}/pipewire-0" \
           "${XDG_RUNTIME_DIR:-/nonexistent}/pipewire-0" \
           /run/pipewire/pipewire-0 /run/pipewire-0 \
           /run/user/*/pipewire-0 /tmp/pipewire-0; do
    [ -S "$s" ] && { echo "$s"; return 0; }
  done
  return 1
}

mcpe_has_alsa_pcm_plugin() {
  local module="$1" p
  for p in /usr/lib*/alsa-lib/libasound_module_pcm_"$module".so \
           /usr/lib/*/alsa-lib/libasound_module_pcm_"$module".so; do
    [ -f "$p" ] && return 0
  done
  return 1
}

# A PipeWire client library with no client.conf cannot open a context at all.
# dArkOS RE has exactly this shape and logs "can't load config client.conf"
# before every audio attempt, so PipeWire must not be offered to OpenAL there.
mcpe_pipewire_client_usable() {
  local p
  for p in "${PIPEWIRE_CONFIG_DIR:-/nonexistent}/client.conf" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/client.conf" \
           /etc/pipewire/client.conf /usr/share/pipewire/client.conf \
           /usr/local/share/pipewire/client.conf; do
    [ -f "$p" ] && return 0
  done
  return 1
}

mcpe_resolve_audio() {
  local pulse_sock="" pulse_up=0 pw_sock="" pw_alsa_plugin=0 p

  if [ -n "${MCPE_ALSOFT_DRIVERS:-}" ]; then
    export ALSOFT_DRIVERS="$MCPE_ALSOFT_DRIVERS"
    echo "audio: ALSOFT_DRIVERS pinned to $ALSOFT_DRIVERS by request"
    return 0
  fi
  [ -z "${ALSOFT_DRIVERS:-}" ] || return 0

  # Resolve and pin a concrete socket before Weston changes XDG_RUNTIME_DIR.
  # Knulli exposes PipeWire-Pulse at /var/run/pulse/native; without this,
  # SDL3 falls through to an unusable ALSA default after the frontend stops.
  if pulse_sock="$(mcpe_find_pulse_socket)"; then
    pulse_up=1
    export PULSE_SERVER="unix:$pulse_sock"
    echo "audio: pulse socket at $pulse_sock"
  elif command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
    pulse_up=1
  elif pidof pulseaudio >/dev/null 2>&1 || pidof pipewire-pulse >/dev/null 2>&1; then
    pulse_up=1
  fi

  if [ "$pulse_up" = 1 ]; then
    # The pinned client includes SDL3's native PulseAudio driver. Prefer it
    # over ALSA's pulse PCM bridge: on Knulli the bridge can open without
    # producing a sink input after ES hands the display to Weston. Keep ALSA
    # second in SDL's driver list for older/minimal Pulse servers.
    if [ -z "${MCPE_SDL_AUDIODRIVER:-}" ]; then
      export MCPE_SDL_AUDIODRIVER=pulseaudio,alsa
      if mcpe_has_alsa_pcm_plugin pulse; then
        export SDL_AUDIO_ALSA_DEFAULT_DEVICE="${SDL_AUDIO_ALSA_DEFAULT_DEVICE:-pulse}"
      fi
      echo "audio: SDL3 native PulseAudio (ALSA fallback)"
    fi
    return 0
  fi

  if pw_sock="$(mcpe_find_pipewire_socket)"; then
    # PipeWire owns the ALSA device; talk to it directly via SDL's
    # pipewire driver (alsa stays in the list as a fallback).
    [ -z "${PIPEWIRE_RUNTIME_DIR:-}" ] &&
      export PIPEWIRE_RUNTIME_DIR="$(dirname "$pw_sock")"
    export MCPE_SDL_AUDIODRIVER="${MCPE_SDL_AUDIODRIVER:-pipewire,alsa}"
    if mcpe_pipewire_client_usable; then
      export ALSOFT_DRIVERS="pipewire,pulse,alsa"
    else
      # Offering PipeWire to OpenAL here only buys the dArkOS failure twice
      # over: a failed context, then a failed RTKit query, before ALSA.
      export ALSOFT_DRIVERS="alsa"
      echo "audio: PipeWire is running but has no client config; keeping OpenAL on ALSA"
    fi
    echo "audio: PipeWire server (no pulse socket) at $pw_sock -> SDL pipewire driver"
    # The shipped SDL3 has no pipewire driver compiled in, so audio really
    # goes SDL3 -> ALSA. Raw/sysdefault ALSA devices are EBUSY while
    # PipeWire runs; give the game an ALSA config whose default AND
    # sysdefault route through the pipewire ALSA plugin (verified on muOS
    # 2601 Jacaranda / RG34XX-SP). Disable with MCPE_ALSA_PIPEWIRE=0.
    for p in /usr/lib*/alsa-lib/libasound_module_pcm_pipewire.so \
             /usr/lib/*/alsa-lib/libasound_module_pcm_pipewire.so; do
      [ -f "$p" ] && { pw_alsa_plugin=1; break; }
    done
    if [ "${MCPE_ALSA_PIPEWIRE:-1}" != 0 ] &&
       [ "$pw_alsa_plugin" = 1 ] &&
       [ -z "${ALSA_CONFIG_PATH:-}" ] &&
       [ -f /usr/share/alsa/alsa.conf ] &&
       [ -f "$GAMEDIR/alsa/pipewire-overlay.conf" ]; then
      if cat /usr/share/alsa/alsa.conf "$GAMEDIR/alsa/pipewire-overlay.conf" \
           > /tmp/mcpe_alsa_pipewire.conf 2>/dev/null; then
        export ALSA_CONFIG_PATH=/tmp/mcpe_alsa_pipewire.conf
        echo "audio: ALSA default/sysdefault routed via pipewire plugin (ALSA_CONFIG_PATH)"
      fi
    fi
    return 0
  fi

  # No sound server at all. OpenAL Soft's built-in preference list would still
  # try PipeWire first and fail twice before reaching ALSA, which is what the
  # 32-bit path used to do because it never ran this triage.
  export ALSOFT_DRIVERS=alsa
  echo "audio: no PulseAudio/PipeWire server found -> routing OpenAL to ALSA"
}
