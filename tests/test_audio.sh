#!/bin/bash
# Audio backend selection, exercised through the real decision function with
# the three device probes stubbed out. Both launch paths call this now; the
# 32-bit one previously had no triage at all (issue #1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GAMEDIR="$TMP/game"
mkdir -p "$GAMEDIR"

# shellcheck disable=SC1091
source "$PAYLOAD/lib/audio.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

reset_audio() {
  unset ALSOFT_DRIVERS MCPE_ALSOFT_DRIVERS MCPE_SDL_AUDIODRIVER PULSE_SERVER
  unset SDL_AUDIO_ALSA_DEFAULT_DEVICE PIPEWIRE_RUNTIME_DIR ALSA_CONFIG_PATH
  # Neutral stubs; each case overrides what it needs.
  mcpe_find_pulse_socket() { return 1; }
  mcpe_find_pipewire_socket() { return 1; }
  mcpe_pipewire_client_usable() { return 1; }
  mcpe_has_alsa_pcm_plugin() { return 1; }
}

# --- A Pulse-compatible server (Knulli, ROCKNIX: pipewire-pulse) ---------------
reset_audio
mcpe_find_pulse_socket() { echo /run/pulse/native; return 0; }
mcpe_resolve_audio >/dev/null
[ "${PULSE_SERVER:-}" = "unix:/run/pulse/native" ] || fail "pulse socket not pinned"
[ "${MCPE_SDL_AUDIODRIVER:-}" = "pulseaudio,alsa" ] || fail "SDL driver not pulseaudio,alsa"
# OpenAL is deliberately left on its own default here: its PipeWire backend
# works when pipewire-pulse is the thing serving Pulse.
[ -z "${ALSOFT_DRIVERS:-}" ] || fail "pulse path pinned ALSOFT_DRIVERS unexpectedly"

# --- PipeWire with no pulse socket, client config present (muOS Jacaranda) -----
reset_audio
mcpe_find_pipewire_socket() { echo /run/pipewire-0; return 0; }
mcpe_pipewire_client_usable() { return 0; }
mcpe_resolve_audio >/dev/null
[ "${ALSOFT_DRIVERS:-}" = "pipewire,pulse,alsa" ] || fail "pipewire path wrong: ${ALSOFT_DRIVERS:-unset}"
[ "${MCPE_SDL_AUDIODRIVER:-}" = "pipewire,alsa" ] || fail "SDL driver not pipewire,alsa"
[ "${PIPEWIRE_RUNTIME_DIR:-}" = "/run" ] || fail "runtime dir not derived from the socket"

# --- PipeWire libraries present but no client config (dArkOS RE, issue #1) -----
# OpenAL would try PipeWire first, fail to create a context, fail to query
# RTKit, and only then reach ALSA. Offering it PipeWire buys nothing.
reset_audio
mcpe_find_pipewire_socket() { echo /run/pipewire-0; return 0; }
mcpe_pipewire_client_usable() { return 1; }
mcpe_resolve_audio >/dev/null
[ "${ALSOFT_DRIVERS:-}" = "alsa" ] ||
  fail "unusable pipewire still offered to OpenAL: ${ALSOFT_DRIVERS:-unset}"

# --- No sound server at all ----------------------------------------------------
# This is what the 32-bit path used to leave unset, which is why OpenAL walked
# its built-in list and tried PipeWire first.
reset_audio
mcpe_resolve_audio >/dev/null
[ "${ALSOFT_DRIVERS:-}" = "alsa" ] || fail "bare host did not pin ALSA"

# --- An explicit request always wins ------------------------------------------
reset_audio
MCPE_ALSOFT_DRIVERS=null
mcpe_find_pulse_socket() { echo /run/pulse/native; return 0; }
mcpe_resolve_audio >/dev/null
[ "${ALSOFT_DRIVERS:-}" = "null" ] || fail "MCPE_ALSOFT_DRIVERS override ignored"
[ -z "${PULSE_SERVER:-}" ] || fail "override still ran device detection"

# --- An already-resolved backend is not second-guessed -------------------------
reset_audio
ALSOFT_DRIVERS=alsa
mcpe_find_pipewire_socket() { echo /run/pipewire-0; return 0; }
mcpe_resolve_audio >/dev/null
[ "${ALSOFT_DRIVERS:-}" = "alsa" ] || fail "pre-set ALSOFT_DRIVERS was overwritten"

# --- The client-config probe looks where PipeWire actually looks ---------------
unset -f mcpe_pipewire_client_usable
source "$PAYLOAD/lib/audio.sh"
# Scope the system paths to an empty probe root, or this asserts about whatever
# PipeWire the build host happens to have. muOS -- one of the hosts this suite
# is run on -- ships /usr/share/pipewire/client.conf, which made the negative
# case unobservable there.
mkdir -p "$TMP/emptyroot"
MCPE_PROBE_ROOT="$TMP/emptyroot" HOME="$TMP/emptyroot" PIPEWIRE_CONFIG_DIR="$TMP/pw" \
  mcpe_pipewire_client_usable &&
  fail "client config reported present when the directory is empty"
mkdir -p "$TMP/pw"
: >"$TMP/pw/client.conf"
MCPE_PROBE_ROOT="$TMP/emptyroot" HOME="$TMP/emptyroot" PIPEWIRE_CONFIG_DIR="$TMP/pw" \
  mcpe_pipewire_client_usable ||
  fail "client config not found where PipeWire would look"

echo "audio backend tests passed"
