#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT/bottomscreen/release/rgds_session.sh"

CALLS="$TMP/calls"
: >"$CALLS"

pgrep() {
  [ "${1:-}" = -P ] || return 1
  case "${2:-}" in
    10) printf '11\n' ;;
    *) return 1 ;;
  esac
}
kill() {
  printf 'kill %s\n' "$*" >>"$CALLS"
  [ "${1:-}" != -0 ]
}
wait() { printf 'wait %s\n' "$*" >>"$CALLS"; }
sleep() { :; }
swaymsg() { printf 'swaymsg %s\n' "$*" >>"$CALLS"; }

RGDS_CLEANED_UP=0
RGDS_GAME_PID=10
RGDS_BOTTOMD_PID=""
RGDS_TERRAIN_PID=""
RGDS_OSK_PID=""
RGDS_DIR="$TMP/rgds"
RGDS_INPUT_STATE=""
RGDS_TOP_OUTPUT=test-top
GAMEDIR="$TMP/game"
MCPE_TELEMETRY_SHM_PATH="$TMP/mcpe_telemetry"
MCPE_COMPANION_STATE_SHM_PATH="$TMP/mcpe_companion_state"
MCPE_COMPANION_CMD_SHM_PATH="$TMP/mcpe_companion_cmd"
mkdir -p "$RGDS_DIR" "$GAMEDIR/logs"
: >"$MCPE_TELEMETRY_SHM_PATH"
: >"$MCPE_COMPANION_STATE_SHM_PATH"
: >"$MCPE_COMPANION_CMD_SHM_PATH"

mcpe_rgds_stop

test "$RGDS_CLEANED_UP" = 1
test ! -e "$MCPE_TELEMETRY_SHM_PATH"
test ! -e "$MCPE_COMPANION_STATE_SHM_PATH"
test ! -e "$MCPE_COMPANION_CMD_SHM_PATH"
grep -qx 'kill -TERM 11' "$CALLS"
grep -qx 'kill -TERM 10' "$CALLS"
grep -qx 'wait 10' "$CALLS"

before="$(wc -l <"$CALLS")"
mcpe_rgds_stop
after="$(wc -l <"$CALLS")"
test "$before" = "$after"

echo "RGDS session cleanup tests passed"
