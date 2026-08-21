#!/bin/bash
set -u
GAMEDIR="${GAMEDIR:-$(cd "$(dirname "$0")" && pwd)}"
MCPE_SHARED_ROOT="${MCPE_SHARED_ROOT:-$(dirname "$GAMEDIR")/minecraftbedrock-data}"
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh" 2>/dev/null || true
OUT="${1:-$GAMEDIR/support-bundle-$(date +%Y%m%d-%H%M%S).tar.gz}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mcpe-support.XXXXXX")" || exit 1
cleanup() {
  case "$TMP" in "${TMPDIR:-/tmp}"/mcpe-support.*) rm -rf -- "$TMP" ;; esac
}
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
cp "$GAMEDIR/bin/mcpelauncher-client.buildinfo" "$TMP/mcpelauncher-client.buildinfo" 2>/dev/null || true
copy_redacted "$GAMEDIR/log.txt" "$TMP/launcher.log"
copy_redacted "$GAMEDIR/weston_launch.log" "$TMP/game.log"
copy_redacted "$GAMEDIR/logs/controller-test.txt" "$TMP/controller-test.txt"
copy_redacted "$GAMEDIR/logs/menu-failure.log" "$TMP/menu-failure.log"
copy_redacted "$GAMEDIR/logs/startup-timing.log" "$TMP/startup-timing.log"
copy_redacted "$GAMEDIR/logs/downloader.log" "$TMP/downloader.log"
copy_redacted "$GAMEDIR/logs/runtime-arm64.env" "$TMP/runtime-arm64.env"
copy_redacted "$GAMEDIR/logs/runtime-armhf.env" "$TMP/runtime-armhf.env"
copy_redacted "$GAMEDIR/setup_error.txt" "$TMP/setup-error.txt"
copy_redacted "$GAMEDIR/install_progress.txt" "$TMP/install-progress.txt"
cp "$GAMEDIR/versions/.install-transaction.json" "$TMP/install-transaction.json" 2>/dev/null || true
{
  printf 'uid='; id 2>/dev/null || true
  printf 'locale_resolved=%s\n' "${MCPE_LOCALE_RESOLVED:-unknown}"
  printf 'LANG=%s\n' "${LANG:-}"
  printf 'LC_ALL=%s\n' "${LC_ALL:-}"
  printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-}"
  [ -n "${XDG_RUNTIME_DIR:-}" ] && ls -ld "$XDG_RUNTIME_DIR" 2>/dev/null || true
  printf 'DISPLAY=%s\n' "${DISPLAY:-}"
  printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
} >"$TMP/session-env.txt"
{
  command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null || true
} >"$TMP/locales.txt"
{
  df -P "$GAMEDIR" "$MCPE_SHARED_ROOT" 2>/dev/null || true
  echo
  mount 2>/dev/null || true
} >"$TMP/storage-mounts.txt"
copy_redacted "$TMP/storage-mounts.txt" "$TMP/storage-mounts.redacted.txt"
mv "$TMP/storage-mounts.redacted.txt" "$TMP/storage-mounts.txt"
{
  cat /proc/asound/cards 2>/dev/null || true
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null || true
  printf '\nAudio processes:\n'
  pidof pipewire pipewire-pulse pulseaudio 2>/dev/null || true
  printf '\nAudio sockets:\n'
  find "${XDG_RUNTIME_DIR:-/nonexistent}" /run -maxdepth 2 \
    \( -name 'pipewire-*' -o -name native \) -print 2>/dev/null || true
} >"$TMP/audio.txt"
{
  for c in /sys/class/drm/card*-*; do
    [ -r "$c/status" ] || continue
    printf '%s status=%s modes=' "$(basename "$c")" "$(cat "$c/status")"
    tr '\n' ',' <"$c/modes" 2>/dev/null
    echo
  done
} >"$TMP/drm.txt"
{
  ls -l /dev/dri /dev/mali /dev/mali0 /dev/fb0 2>/dev/null || true
  printf '\nLoaded graphics modules:\n'
  grep -E '^(mali|panfrost|lima|drm|sun4i)' /proc/modules 2>/dev/null || true
} >"$TMP/device-permissions.txt"
grep -E '^(N: Name|H: Handlers|B: EV=|B: KEY=|B: ABS=)' /proc/bus/input/devices >"$TMP/input.txt" 2>/dev/null || true
cp "$GAMEDIR/controls/rg34xxsp.gamecontrollerdb.txt" "$TMP/controller-aliases.txt" 2>/dev/null || true
for metadata in "$MCPE_SHARED_ROOT"/versions/*/version.json; do
  [ -f "$metadata" ] || continue
  cp "$metadata" "$TMP/version-$(basename "$(dirname "$metadata")").json"
done
find "$GAMEDIR/runtime" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r f; do
  printf '%s  %s\n' "$(mcpe_sha256 "$f" 2>/dev/null || echo unavailable)" "$(basename "$f")"
done >"$TMP/runtime-hashes.txt"
{
  for binary in "$GAMEDIR/bin/mcpelauncher-client" "$GAMEDIR/bin32/mcpelauncher-client"; do
    [ -f "$binary" ] || continue
    echo "--- $binary ---"
    command -v file >/dev/null 2>&1 && file "$binary" 2>/dev/null || true
    command -v readelf >/dev/null 2>&1 && readelf -h -d "$binary" 2>/dev/null || true
  done
} >"$TMP/client-elf.txt"
{
  for binary in "$GAMEDIR/bin/mcpelauncher-client" "$GAMEDIR/bin32/mcpelauncher-client"; do
    [ -f "$binary" ] || continue
    printf '%s  %s\n' "$(mcpe_sha256 "$binary" 2>/dev/null || echo unavailable)" "${binary#$GAMEDIR/}"
  done
} >"$TMP/client-hashes.txt"
tar czf "$OUT" -C "$TMP" . || exit 1
echo "$OUT"
