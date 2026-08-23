#!/bin/bash
# Startup watchdog behaviour, against processes that really do stall or really
# do make progress. The watchdog finds its target with `pidof
# mcpelauncher-client`, so the fixtures are a copy of /bin/sleep under that
# name -- a shell script would show up as "bash" and never be found.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
TMP="$(mktemp -d)"
export GAMEDIR="$TMP/game"
mkdir -p "$GAMEDIR/logs" "$TMP/bin"

cleanup() {
  pkill -9 -f "$TMP/bin/mcpelauncher-client" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cp /bin/sleep "$TMP/bin/mcpelauncher-client"
LOG="$GAMEDIR/logs/client.log"

# shellcheck disable=SC1091
source "$PAYLOAD/lib/common.sh"
# shellcheck disable=SC1091
source "$PAYLOAD/lib/watchdog.sh"
mcpe_stage_begin "$GAMEDIR/logs"

# Started inline rather than through a helper: a background child captured
# with $(...) holds the command-substitution pipe open, so the assignment would
# block for the child's whole lifetime instead of returning its pid.
start_fake_client() { # seconds -> sets $pid
  "$TMP/bin/mcpelauncher-client" "$1" >/dev/null 2>&1 &
  pid=$!
}

# --- A client that stops progressing is terminated, with a report -------------
: >"$LOG"
rm -f "$GAMEDIR/logs/hang-report.txt"
unset MCPE_FRAME_METRICS
export MCPE_STALL_SECONDS=3 MCPE_STARTUP_TIMEOUT=0
start_fake_client 120
mcpe_watchdog_start "$pid" "$LOG" >/dev/null
# sleep(1) burns no CPU and writes nothing, so this is a stall by every signal.
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
  sleep 1
  waited=$((waited + 1))
done
kill -0 "$pid" 2>/dev/null && fail "a stalled client was left running after ${waited}s"
mcpe_watchdog_stop
[ -s "$GAMEDIR/logs/hang-report.txt" ] || fail "no hang report was written"
grep -q 'no progress for' "$GAMEDIR/logs/hang-report.txt" || fail "hang report has no reason"
grep -q 'last 200 log lines' "$GAMEDIR/logs/hang-report.txt" || fail "hang report has no log tail"
grep -q "failsafe rung" "$GAMEDIR/logs/hang-report.txt" || fail "hang report omits the rung"

# --- A client that is still logging is left alone ------------------------------
# A first launch on a cold microSD card is slow but healthy; killing it would
# be a worse bug than the hang this watchdog exists for.
: >"$LOG"
rm -f "$GAMEDIR/logs/hang-report.txt"
export MCPE_STALL_SECONDS=3
start_fake_client 12
( for _ in 1 2 3 4 5 6 7 8; do echo "still loading" >>"$LOG"; sleep 1; done ) &
writer=$!
mcpe_watchdog_start "$pid" "$LOG" >/dev/null
sleep 8
kill -0 "$pid" 2>/dev/null || fail "a client that was still logging got killed"
[ -e "$GAMEDIR/logs/hang-report.txt" ] && fail "a healthy start produced a hang report"
mcpe_watchdog_stop
kill "$pid" "$writer" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
wait "$writer" 2>/dev/null || true

# --- A frame metrics row disarms the watchdog and records the stage ------------
: >"$LOG"
rm -f "$GAMEDIR/logs/hang-report.txt"
export MCPE_FRAME_METRICS="$TMP/frames.csv"
printf 'frame,epoch_us\n1,1000\n' >"$MCPE_FRAME_METRICS"
export MCPE_STALL_SECONDS=3
start_fake_client 12
mcpe_watchdog_start "$pid" "$LOG" >/dev/null
sleep 6
kill -0 "$pid" 2>/dev/null || fail "watchdog killed a client that had drawn a frame"
[ "$(cut -f1 <"$GAMEDIR/logs/stage.txt")" = first-frame ] ||
  fail "first-frame stage not recorded: $(cut -f1 <"$GAMEDIR/logs/stage.txt")"
mcpe_watchdog_stop
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
unset MCPE_FRAME_METRICS

# --- The window stage is recorded from the client log --------------------------
: >"$LOG"
mcpe_stage client-exec
export MCPE_STALL_SECONDS=30
start_fake_client 8
echo '[Launcher] Creating window' >>"$LOG"
mcpe_watchdog_start "$pid" "$LOG" >/dev/null
sleep 4
[ "$(cut -f1 <"$GAMEDIR/logs/stage.txt")" = window ] ||
  fail "window stage not recorded: $(cut -f1 <"$GAMEDIR/logs/stage.txt")"
mcpe_watchdog_stop
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

# --- It can be switched off entirely -------------------------------------------
mcpe_watchdog_pid=""
MCPE_STALL_SECONDS=0 MCPE_STARTUP_TIMEOUT=0 mcpe_watchdog_start 1 "$LOG" >/dev/null
[ -z "${mcpe_watchdog_pid:-}" ] || fail "watchdog started while disabled"

echo "startup watchdog tests passed"
