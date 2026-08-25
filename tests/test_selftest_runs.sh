#!/bin/bash
# Run selftest.sh for real, against a captured device fixture.
#
# tests/test_cfw_contracts.py only greps this script for strings, which is how a
# false "Weston runtime missing" warning shipped in rc.12 and how a raw shell
# error reached a fresh muOS card's first report. Neither would have survived
# executing it once. This does that: a throwaway GAMEDIR, the captured muOS
# probe root, and assertions on the report it produces.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
FIXTURE="$ROOT/tests/fixtures/muos-2601.0"
[ -d "$FIXTURE" ] || { echo "captured muOS fixture missing" >&2; exit 1; }

# A GAMEDIR of its own, so the run cannot write into the repository.
GAME="$TMP/game"
mkdir -p "$GAME"
cp -r "$PAYLOAD"/. "$GAME"/
rm -rf "$GAME/logs"

unset CFW_NAME MCPE_CFW_OVERRIDE MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY

# PortMaster is searched for at absolute paths, none of which exist on a build
# host, and without it the run reports a hard failure that says nothing about
# the code under test. One entry in that search list honours XDG_DATA_HOME, so
# the stub goes there rather than production code gaining a test-only override.
mkdir -p "$TMP/xdg/PortMaster"
printf '# stub for tests\n' >"$TMP/xdg/PortMaster/control.txt"

set +e
MCPE_GAMEDIR="$GAME" GAMEDIR="$GAME" XDG_DATA_HOME="$TMP/xdg" \
MCPE_PROBE_ROOT="$FIXTURE" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=none \
MCPE_TEST_FB_MODE=720x480 \
  bash "$GAME/selftest.sh" >"$TMP/out.txt" 2>"$TMP/err.txt"
rc=$?
set -e

# 1. It must never fail outright on a device it can describe.
[ "$rc" = 0 ] || {
  echo "selftest.sh exited $rc against the captured fixture" >&2
  grep -E '^\[FAIL\]' "$TMP/out.txt" >&2 || tail -5 "$TMP/out.txt" >&2
  exit 1; }
! grep -q '^\[FAIL\]' "$TMP/out.txt" || {
  echo "the captured fixture produced a hard failure:" >&2
  grep -E '^\[FAIL\]' "$TMP/out.txt" >&2; exit 1; }

# 2. Nothing may reach stderr. A fresh install has no logs at all, and the
#    report is the thing a player pastes into an issue -- a raw shell error in
#    it is both alarming and useless.
[ ! -s "$TMP/err.txt" ] || {
  echo "selftest.sh wrote to stderr:" >&2; cat "$TMP/err.txt" >&2; exit 1; }

# 3. The report must describe the fixture, not the build host.
grep -q "muos" "$TMP/out.txt" || {
  echo "the report does not name the captured firmware" >&2; exit 1; }
grep -Eq "^summary: [0-9]+ ok" "$TMP/out.txt" || {
  echo "the report has no summary line" >&2; exit 1; }

# 4. Audio is reported from the capture, not from the build host. The fixture
#    could not make this check until PipeWire and Pulse detection began
#    honouring MCPE_PROBE_ROOT: the muOS device resolves pipewire, so must its
#    capture.
grep -q "audio backend" "$TMP/out.txt" && grep -q "pipewire" "$TMP/out.txt" || {
  echo "the report should resolve pipewire from the captured muOS root" >&2
  grep -i audio "$TMP/out.txt" >&2; exit 1; }

# 5. It answers before anything is installed, which is its whole purpose.
grep -q "no Bedrock version installed" "$TMP/out.txt" || {
  echo "a fixture with no versions must say so rather than failing" >&2; exit 1; }

# 6. It must not have started the game.
for forbidden in mcpelauncher-client wp_weston; do
  ! grep -q "$forbidden" "$TMP/out.txt" || {
    echo "the self test appears to have launched $forbidden" >&2; exit 1; }
done

echo "selftest execution tests passed"
