#!/bin/bash
# The shell half of the ladder: what each rung actually does to the launch
# environment, and that it survives being driven repeatedly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GAMEDIR="$TMP/game"
mkdir -p "$GAMEDIR/config" "$GAMEDIR/logs"
cp "$PAYLOAD/failsafe_state.py" "$GAMEDIR/"
# shellcheck disable=SC1091
source "$PAYLOAD/lib/common.sh"
# shellcheck disable=SC1091
source "$PAYLOAD/lib/failsafe.sh"

export MCPE_PORT_VERSION=2.0.0 MCPE_CFW=knulli MCPE_BEDROCK_VERSION_NAME=1.16.221.01
unset MCPE_ABI_OVERRIDE MCPE_SAFE_MODE MCPE_STAGE_PREV || true

fail() { echo "FAIL: $*" >&2; exit 1; }

reset_env() {
  unset MCPE_PERFORMANCE_MODE MCPE_PERFORMANCE_OPTIONS MCPE_VSYNC MCPE_MAX_FPS
  unset MCPE_FAKE_NO_NETWORK SDL_DRIVER_OVERRIDE GAMEWINDOW_EGLUT_CRUSTY_CONTEXT
  unset MCPE_ALSOFT_DRIVERS MCPE_SDL_AUDIODRIVER MCPE_PREWARM_GAMEPLAY_ASSETS
  # The H700 profile sets these before the ladder is consulted.
  export MCPE_PIN_RENDER_CORE=3 MCPE_PIN_MAIN_CORE=2 MCPE_PIN_OTHER_CORES=0-1
  export MCPE_FAKE_NPROC=2
}

# --- Rung 0 leaves a tuned launch completely alone -----------------------------
reset_env
MCPE_FAILSAFE_RUNG=0 mcpe_failsafe_apply
[ "${MCPE_PIN_RENDER_CORE:-unset}" = 3 ] || fail "rung 0 disturbed thread pinning"
[ -z "${MCPE_FAKE_NO_NETWORK:-}" ] || fail "rung 0 forced offline mode"
[ -z "${MCPE_ALSOFT_DRIVERS:-}" ] || fail "rung 0 touched audio"

# --- Rung 1 drops the tuning but keeps the stack -------------------------------
reset_env
MCPE_FAILSAFE_RUNG=1 mcpe_failsafe_apply
[ "${MCPE_PERFORMANCE_MODE}" = 0 ] || fail "rung 1 left the governor override on"
[ "${MCPE_PERFORMANCE_OPTIONS}" = 0 ] || fail "rung 1 still rewrites options.txt"
[ "${MCPE_VSYNC}" = 1 ] && [ "${MCPE_MAX_FPS}" = 30 ] || fail "rung 1 fps/vsync wrong"
[ "${MCPE_FAKE_NO_NETWORK}" = 1 ] || fail "rung 1 did not enable offline mode"
[ -z "${MCPE_PIN_RENDER_CORE:-}" ] || fail "rung 1 kept the H700 render pin"
[ -z "${MCPE_FAKE_NPROC:-}" ] || fail "rung 1 kept the faked CPU count"
# The display and audio stack must be untouched at rung 1: it is the rung for
# "the tuning was the problem", not "the stack was the problem".
[ -z "${SDL_DRIVER_OVERRIDE:-}" ] || fail "rung 1 changed the video driver"
[ -z "${MCPE_ALSOFT_DRIVERS:-}" ] || fail "rung 1 silenced audio"

# --- Rung 2 is rung 1 plus stack changes ---------------------------------------
reset_env
MCPE_FAILSAFE_RUNG=2 mcpe_failsafe_apply
[ "${MCPE_PERFORMANCE_MODE}" = 0 ] || fail "rung 2 did not inherit rung 1"
[ -z "${MCPE_PIN_RENDER_CORE:-}" ] || fail "rung 2 did not inherit rung 1 pinning"
[ "${MCPE_FAKE_NO_NETWORK}" = 1 ] || fail "rung 2 did not inherit offline mode"
[ "${SDL_DRIVER_OVERRIDE}" = x11 ] || fail "rung 2 did not fall back to x11"
[ "${GAMEWINDOW_EGLUT_CRUSTY_CONTEXT}" = 0 ] || fail "rung 2 kept the context hand-off"
[ "${MCPE_ALSOFT_DRIVERS}" = null ] || fail "rung 2 did not silence OpenAL"
[ "${MCPE_SDL_AUDIODRIVER}" = dummy ] || fail "rung 2 did not silence SDL audio"
[ "${MCPE_MAX_FPS}" = 20 ] || fail "rung 2 fps cap wrong"

# --- Every rung describes itself, for the on-screen notice ---------------------
for rung in 0 1 2 3; do
  [ -n "$(MCPE_FAILSAFE_RUNG=$rung mcpe_failsafe_describe)" ] ||
    fail "rung $rung has no description"
done

# --- plan/record drive the real state file -------------------------------------
reset_env
mcpe_failsafe_plan
[ "$MCPE_FAILSAFE_RUNG" = 0 ] || fail "a fresh install did not start at rung 0"
[ "$MCPE_FAILSAFE_PINNED" = 0 ] || fail "a fresh install reported itself pinned"
mcpe_failsafe_record 1 3
[ "$MCPE_FAILSAFE_OUTCOME" = startup_failure ] || fail "quick non-zero exit misread"
[ "$MCPE_FAILSAFE_NEXT_RUNG" = 1 ] || fail "startup failure did not escalate"

mcpe_failsafe_plan
[ "$MCPE_FAILSAFE_RUNG" = 1 ] || fail "escalation did not carry to the next launch"
mcpe_failsafe_apply
[ "${MCPE_FAKE_NO_NETWORK:-}" = 1 ] || fail "rung 1 not applied after planning"
mcpe_failsafe_record 0 900
[ "$MCPE_FAILSAFE_OUTCOME" = success ] || fail "clean exit misread"

# The key must change with the port build so an update gets a fresh chance.
before="$(mcpe_failsafe_key)"
MCPE_PORT_VERSION=2.0.1 mcpe_failsafe_key | grep -q '^2\.0\.1|' ||
  fail "the ladder key ignores the port build"
[ "$before" != "$(MCPE_PORT_VERSION=2.0.1 mcpe_failsafe_key)" ] ||
  fail "the ladder key did not change with the port build"

# --- A pin overrides the learned rung in both directions -----------------------
MCPE_SAFE_MODE=2 mcpe_failsafe_plan
[ "$MCPE_FAILSAFE_RUNG" = 2 ] || fail "MCPE_SAFE_MODE did not pin upward"
[ "$MCPE_FAILSAFE_PINNED" = 1 ] || fail "pinning was not reported"
MCPE_SAFE_MODE=0 mcpe_failsafe_plan
[ "$MCPE_FAILSAFE_RUNG" = 0 ] || fail "MCPE_SAFE_MODE=0 did not force the tuned profile"

# --- A broken state file must not block the launch -----------------------------
printf 'not json at all' >"$GAMEDIR/config/launch_state.json"
mcpe_failsafe_plan
[ "$MCPE_FAILSAFE_RUNG" = 0 ] || fail "corrupt state did not fall back to rung 0"

# --- A missing helper must not block the launch either -------------------------
mv "$GAMEDIR/failsafe_state.py" "$GAMEDIR/failsafe_state.py.away"
unset MCPE_FAILSAFE_RUNG
mcpe_failsafe_plan >/dev/null
[ "$MCPE_FAILSAFE_RUNG" = 0 ] || fail "a missing state helper did not degrade to rung 0"
mcpe_failsafe_record 0 900 >/dev/null
mv "$GAMEDIR/failsafe_state.py.away" "$GAMEDIR/failsafe_state.py"

[ -s "$GAMEDIR/logs/failsafe-ledger.tsv" ] || fail "no ledger was written"
head -1 "$GAMEDIR/logs/failsafe-ledger.tsv" | grep -q '^timestamp' ||
  fail "the ledger has no header"

echo "failsafe apply tests passed"
