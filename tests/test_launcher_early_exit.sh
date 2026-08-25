#!/bin/bash
# Run the real launcher, on a device that has neither a Bedrock version nor
# PortMaster's LOVE runtime, and assert on what a player would be told.
#
# This is the shape issue #10 arrived in: a muOS device where the menu never
# appeared, whose reporter pasted log.txt into the template twice. Everything
# that would have identified the problem was in logs/boot-report.txt, which
# nothing ever copied into the log, and the only message on screen blamed a
# missing Minecraft version rather than the missing runtime that actually
# stopped the menu.
#
# tests/test_portability_contracts.py greps the launcher for the strings that
# fix this. Grepping is how a false warning shipped in rc.12; this executes it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
FIXTURE="$ROOT/tests/fixtures/muos-2601.0"
[ -d "$FIXTURE" ] || { echo "captured muOS fixture missing" >&2; exit 1; }

# A ports tree of its own, so the run cannot write into the repository.
PORT="$TMP/ports"
GAME="$PORT/minecraftbedrock"
mkdir -p "$GAME"
cp -r "$PAYLOAD"/. "$GAME"/
rm -rf "$GAME/logs"
cp "$ROOT/portmaster/minecraftbedrock/Minecraft Bedrock.sh" "$PORT/"

# The launcher refuses a non-ARM host outright, before it loads anything this
# test is about. Rather than give production code a test-only architecture
# override, shadow uname on PATH for the duration of the run -- the same
# reasoning as the PortMaster stub below.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/uname" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-m" ] && { echo aarch64; exit 0; }
exec /usr/bin/uname "$@"
STUB
chmod +x "$TMP/bin/uname"

# PortMaster is searched for at absolute paths, none of which exist on a build
# host. One entry in that list honours XDG_DATA_HOME, so the stub goes there.
# It deliberately carries no runtimes/: a PortMaster without the LOVE runtime
# is precisely the device under test.
mkdir -p "$TMP/xdg/PortMaster"
printf '# stub for tests\n' >"$TMP/xdg/PortMaster/control.txt"

unset CFW_NAME MCPE_CFW_OVERRIDE MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY

set +e
PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_DATA_HOME="$TMP/xdg" \
MCPE_PROBE_ROOT="$FIXTURE" MCPE_TEST_ARCH=aarch64 MCPE_TEST_COMPOSITOR=none \
MCPE_TEST_FB_MODE=720x480 MCPE_MENU=auto \
  timeout 120 bash "$PORT/Minecraft Bedrock.sh" >"$TMP/out.txt" 2>"$TMP/err.txt"
rc=$?
set -e

LOG="$GAME/logs/launcher.log"
REPORT="$GAME/logs/boot-report.txt"

fail() { echo "$1" >&2; echo "--- stdout ---" >&2; cat "$TMP/out.txt" >&2
         echo "--- stderr ---" >&2; cat "$TMP/err.txt" >&2; exit 1; }

# 1. It stops, rather than launching something with hidden defaults.
[ "$rc" = 1 ] || fail "expected exit 1 with no version and no runtime, got $rc"
[ -s "$LOG" ] || fail "no launcher log was written"

# 2. The boot report reaches the log, which is the file reporters paste.
grep -q -- "--- boot report ---" "$LOG" ||
  fail "the boot report never reached the launcher log"
# Exactly once, so a second trap cannot append a second copy. Note the limit:
# on this path mcpe_report_print is only reached from the EXIT trap, so removing
# its idempotency guard does not show up here. The case it protects -- the
# normal path, which prints explicitly and then exits through the trap -- needs
# a launch, so that half is pinned by tests/test_portability_contracts.py.
[ "$(grep -c -- "--- boot report ---" "$LOG")" = 1 ] ||
  fail "the boot report was printed more than once"

# 3. It names the runtime as the reason the menu is missing, and does so before
#    talking about Minecraft versions.
grep -q "LOVE 11.5 runtime was not found" "$LOG" ||
  fail "the log does not say why the menu could not start"
menu_line="$(grep -n "LOVE 11.5 runtime was not found" "$LOG" | head -1 | cut -d: -f1)"
version_line="$(grep -n "No Minecraft version installed" "$LOG" | head -1 | cut -d: -f1)"
[ -n "$version_line" ] && [ "$menu_line" -le "$version_line" ] ||
  fail "the missing runtime must be reported before the missing version"

# 4. The report carries the fields a device report needs, from the fixture
#    rather than from the build host.
for field in "menu=unavailable" "menu_searched=" "cfw_support=" \
             "cfw=muos" "graphics=backend=mali" "edition=minecraftbedrock.standard"; do
  grep -q "$field" "$REPORT" || fail "the boot report is missing '$field'"
done
# The searched paths are printed for the reader; a repeated one reads as a bug.
searched="$(sed -n 's/^menu_searched=//p' "$REPORT")"
[ -n "$searched" ] || fail "menu_searched is empty"
duplicates="$(printf '%s\n' $searched | sort | uniq -d)"
[ -z "$duplicates" ] || fail "menu_searched repeats a path: $duplicates"

# 5. muOS is a firmware this release covers; the report must say so.
grep -q "cfw_support=reference" "$REPORT" ||
  fail "a measured firmware must be reported as covered"

# 6. Nothing may reach stderr, and nothing may have been started.
[ ! -s "$TMP/err.txt" ] ||
  { echo "the launcher wrote to stderr:" >&2; cat "$TMP/err.txt" >&2; exit 1; }
for forbidden in mcpelauncher-client wp_weston bottomd; do
  ! grep -q "$forbidden" "$LOG" || fail "the launcher appears to have started $forbidden"
done

echo "launcher early-exit execution tests passed"
