#!/bin/bash
set -u
GAMEDIR="${GAMEDIR:-$(cd "$(dirname "$0")" && pwd)}"
MCPE_SHARED_ROOT="${MCPE_SHARED_ROOT:-$(dirname "$GAMEDIR")/minecraftbedrock-data}"
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh" 2>/dev/null || true
OUT="${1:-$GAMEDIR/support-bundle-$(date +%Y%m%d-%H%M%S).tar.gz}"
TMP="${TMPDIR:-/tmp}/mcpe-support-$$"
mkdir -p "$TMP" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

copy_redacted() {
  [ -f "$1" ] || return 0
  sed -E \
    -e 's#(https?://)[^/@[:space:]]+@#\1REDACTED@#g' \
    -e 's#(token|password|passwd|authorization)[=:][^[:space:]]+#\1=REDACTED#Ig' \
    -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#REDACTED_IP#g' "$1" >"$2"
}

uname -a >"$TMP/uname.txt" 2>&1
cp /etc/os-release "$TMP/os-release.txt" 2>/dev/null || true
grep -E 'MemTotal|MemAvailable' /proc/meminfo >"$TMP/memory.txt" 2>/dev/null || true
cp "$GAMEDIR/config/resolved_host.env" "$TMP/resolved_host.env" 2>/dev/null || true
cp "$GAMEDIR/edition.json" "$TMP/edition.json" 2>/dev/null || true
cp "$GAMEDIR/PORT_VERSION" "$TMP/PORT_VERSION" 2>/dev/null || true
copy_redacted "$GAMEDIR/log.txt" "$TMP/launcher.log"
copy_redacted "$GAMEDIR/weston_launch.log" "$TMP/game.log"
copy_redacted "$GAMEDIR/logs/controller-test.txt" "$TMP/controller-test.txt"
{
  for c in /sys/class/drm/card*-*; do
    [ -r "$c/status" ] || continue
    printf '%s status=%s modes=' "$(basename "$c")" "$(cat "$c/status")"
    tr '\n' ',' <"$c/modes" 2>/dev/null
    echo
  done
} >"$TMP/drm.txt"
grep -E '^(N: Name|H: Handlers|B: EV=|B: KEY=|B: ABS=)' /proc/bus/input/devices >"$TMP/input.txt" 2>/dev/null || true
for metadata in "$MCPE_SHARED_ROOT"/versions/*/version.json; do
  [ -f "$metadata" ] || continue
  cp "$metadata" "$TMP/version-$(basename "$(dirname "$metadata")").json"
done
find "$GAMEDIR/runtime" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r f; do
  printf '%s  %s\n' "$(mcpe_sha256 "$f" 2>/dev/null || echo unavailable)" "$(basename "$f")"
done >"$TMP/runtime-hashes.txt"
tar czf "$OUT" -C "$TMP" . || exit 1
echo "$OUT"
