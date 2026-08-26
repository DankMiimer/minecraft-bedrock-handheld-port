#!/bin/bash
# Run the real launcher on the captured ROCKNIX fixture, with sway running, and
# assert that a message meant for the player is actually drawn.
#
# The bug this pins: show_msg's console rung is skipped on purpose under a
# compositor, but the check that followed it asked only whether the console was
# *visible* -- and /proc/consoles on ROCKNIX lists tty0, so it said yes. The
# function returned having written nothing to the panel, and the LOVE and
# framebuffer rungs below were never reached. Every message on that firmware
# went to the log only: the RGDS redirect ("install the RGDS edition"), the
# failsafe notices, the no-version text. On an RG DS the port appeared to exit
# for no reason when the player pressed Play.
#
# Reported from an RG DS on ROCKNIX against 2.0.0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
FIXTURE="$ROOT/tests/fixtures/rocknix-20260822"
[ -d "$FIXTURE" ] || { echo "captured ROCKNIX fixture missing" >&2; exit 1; }
# The fixture has to carry the console line that makes this fail, or the test
# would pass for the wrong reason on a fixture that never reproduced it.
grep -qE '^tty[0-9]' "$FIXTURE/proc/consoles" ||
  { echo "fixture lost the tty console line this test depends on" >&2; exit 1; }

PORT="$TMP/ports"
GAME="$PORT/minecraftbedrock"
mkdir -p "$GAME"
cp -r "$PAYLOAD"/. "$GAME"/
rm -rf "$GAME/logs"
cp "$ROOT/portmaster/minecraftbedrock/Minecraft Bedrock.sh" "$PORT/"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/uname" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-m" ] && { echo aarch64; exit 0; }
exec /usr/bin/uname "$@"
STUB
# The device under test is running a compositor. Shadowing pidof is how that is
# expressed without a test-only branch in production code.
cat >"$TMP/bin/pidof" <<'STUB'
#!/bin/sh
[ "${1:-}" = sway ] && { echo 1234; exit 0; }
exit 1
STUB
chmod +x "$TMP/bin/uname" "$TMP/bin/pidof"

mkdir -p "$TMP/xdg/PortMaster"
printf '# stub for tests\n' >"$TMP/xdg/PortMaster/control.txt"

# A LOVE runtime for the message box only. The menu is switched off below, so
# this is reached solely through show_msg's LOVE rung -- which is the rung the
# bug skipped. The stub records that it ran and draws nothing.
mkdir -p "$TMP/love"
cat >"$TMP/love/love.txt" <<STUB
export LOVE_RUN="$TMP/bin/love-stub"
STUB
cat >"$TMP/bin/love-stub" <<STUB
#!/bin/sh
printf 'drawn\n' >>"$TMP/love-ran.txt"
exit 0
STUB
chmod +x "$TMP/bin/love-stub"

unset CFW_NAME MCPE_CFW_OVERRIDE MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY

# MCPE_MENU=0 takes the launcher to the no-version message, which is a plain
# show_msg call reached without a Bedrock version installed. Any show_msg would
# do; this is the shortest path to one.
set +e
PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_DATA_HOME="$TMP/xdg" \
MCPE_PROBE_ROOT="$FIXTURE" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=sway \
MCPE_TEST_FB_MODE=640x480 MCPE_MENU=0 \
MCPE_MSG_LOVE_TXT="$TMP/love/love.txt" SHOW_MSG_SLEEP=0 \
  timeout 120 bash "$PORT/Minecraft Bedrock.sh" >"$TMP/out.txt" 2>"$TMP/err.txt"
rc=$?
set -e

fail() { echo "$1" >&2; echo "--- stdout ---" >&2; cat "$TMP/out.txt" >&2
         echo "--- stderr ---" >&2; cat "$TMP/err.txt" >&2; exit 1; }

[ "$rc" = 1 ] || fail "expected exit 1 with no version installed, got $rc"

# The point of the test. Before the fix both of these were absent: show_msg
# returned at the console check having drawn nothing at all.
[ -f "$TMP/love-ran.txt" ] ||
  fail "the message was never drawn -- show_msg returned without reaching a rung the player can see"
MSG="$GAME/logs/message.txt"
[ -s "$MSG" ] || fail "no message file was written for the message box to render"
grep -q "No Minecraft version installed" "$MSG" ||
  fail "the rendered message is not the one the player needed"

# The console rung must still be skipped, not merely supplemented: writing to
# tty1 under a compositor is what the sway guard exists to prevent.
grep -q "MINECRAFT BEDROCK ===" "$TMP/out.txt" &&
  fail "the console banner was produced on a device running a compositor"

# And the log keeps its copy either way, since that is what a reporter pastes.
grep -q "No Minecraft version installed" "$GAME/logs/launcher.log" ||
  fail "the message did not reach the launcher log"

[ ! -s "$TMP/err.txt" ] ||
  { echo "the launcher wrote to stderr:" >&2; cat "$TMP/err.txt" >&2; exit 1; }

echo "message delivery tests passed"
