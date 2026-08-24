#!/bin/bash
# Answer "will this port work on my device?" without installing an APK or
# starting Minecraft.
#
# dArkOS has no reference device in this project, so its contract in
# docs/CFW-CONTRACTS.md is an assumption. This exists so a reporter can turn
# "it crashes" into a structured answer before anyone guesses. It is also what
# produced the muOS contract: everything that firmware's row claims, apart from
# the behaviour of a running game, came from one run of this script.
#
# Read-only apart from its own report file. Output is short, redacted with the
# same filter as the support bundle, and meant to be pasted into an issue.
#
#   bash selftest.sh              print a report
#   bash selftest.sh --quiet      only the summary and any WARN/FAIL lines
# Exit status: 0 if nothing failed, 1 if any check failed.
set -u

GAMEDIR="${GAMEDIR:-$(cd "$(dirname "$0")" && pwd)}"
export GAMEDIR
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

PASS=0; WARN=0; FAIL=0
REPORT="$GAMEDIR/logs/selftest.txt"
mkdir -p "$GAMEDIR/logs" 2>/dev/null || true

say() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || say "[ ok ] $1${2:+ — $2}"; }
warn() { WARN=$((WARN+1)); say "[warn] $1${2:+ — $2}"; }
bad()  { FAIL=$((FAIL+1)); say "[FAIL] $1${2:+ — $2}"; }
head_() { [ "$QUIET" = 1 ] || { say ""; say "-- $1"; }; }

# ---------------------------------------------------------------- environment
for lib in common.sh platform.sh abi.sh audio.sh; do
  # shellcheck disable=SC1090
  . "$GAMEDIR/lib/$lib" 2>/dev/null || { say "[FAIL] cannot load lib/$lib"; exit 1; }
done

mcpe_selftest_main() {
say "Minecraft Bedrock port self-test"
say "port     : $(cat "$GAMEDIR/PORT_VERSION" 2>/dev/null || echo unknown)"
say "edition  : $(mcpe_json_string "$GAMEDIR/edition.json" id 2>/dev/null || echo unknown)"
say "date     : $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"

# ------------------------------------------------------------------- identity
head_ "firmware"
mcpe_resolve_cfw
case "$MCPE_CFW" in
  knulli|muos|rocknix|arkos|batocera)
    ok "firmware identified" "$MCPE_CFW ($MCPE_CFW_CONFIDENCE)" ;;
  *)
    warn "firmware not recognised" \
         "reported as '$MCPE_CFW'; per-firmware behaviour falls back to generic" ;;
esac
case "$MCPE_CFW" in
  arkos) warn "firmware has no reference device" \
      "its contract in docs/CFW-CONTRACTS.md is assumed, not measured" ;;
esac

# ------------------------------------------------------------------- python
head_ "python"
if PY_FAULT="$(mcpe_python_health)"; then
  ok "python3 usable" "$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)"
else
  bad "python3 cannot import the standard library"       "$(printf '%s' "$PY_FAULT" | tr '
' ' ' | cut -c1-120)"
  mcpe_python_health_hint "$PY_FAULT" | while IFS= read -r hint_line; do
    say "       $hint_line"
  done
fi

# ------------------------------------------------------------- capabilities
head_ "device"
mcpe_probe_platform "$GAMEDIR/logs/selftest-host.env" 2>/dev/null
# shellcheck disable=SC1090
. "$GAMEDIR/logs/selftest-host.env" 2>/dev/null
ok "model" "${MCPE_HOST_MODEL:-unknown} (profile ${MCPE_HOST_PROFILE:-generic}, ${MCPE_HOST_ARCH:-unknown})"
mem_mb=$(( ${MCPE_HOST_MEMORY_KB:-0} / 1024 ))
if [ "$mem_mb" -ge 900 ]; then ok "memory" "${mem_mb} MB"
elif [ "$mem_mb" -gt 0 ]; then warn "memory is low" "${mem_mb} MB; expect the 32-bit path or reduced settings"
else warn "memory unknown" ""; fi

case "${MCPE_GRAPHICS_BACKEND_RESOLVED:-none}" in
  none) bad "no graphics backend" "no compositor, no /dev/dri, no Mali/fbdev combination found" ;;
  *)    ok "graphics backend" "${MCPE_GRAPHICS_BACKEND_RESOLVED} (compositor ${MCPE_HOST_COMPOSITOR:-none})" ;;
esac
if [ "${MCPE_ACTIVE_WIDTH:-0}" -gt 0 ] && [ "${MCPE_ACTIVE_HEIGHT:-0}" -gt 0 ]; then
  ok "panel" "${MCPE_ACTIVE_WIDTH}x${MCPE_ACTIVE_HEIGHT}"
else
  bad "panel size unknown" "the client would guess its window size; see docs/CFW-CONTRACTS.md"
fi
[ "${MCPE_HAS_DRM:-0}" = 1 ] && [ "${MCPE_DRM_WRITABLE:-0}" = 0 ] &&
  warn "/dev/dri not writable by this user" "a direct-KMS launch would need ESUDO"

# ------------------------------------------------------------------------ ABI
head_ "client"
have64=0; have32=0
mcpe_loader_present arm64 && have64=1
mcpe_loader_present armhf && have32=1
[ -f "$GAMEDIR/bin/mcpelauncher-client" ] || have64=0
[ -f "$GAMEDIR/bin32/mcpelauncher-client" ] || have32=0
[ -e /dev/dri/card0 ] || have32=0
if [ "$have64" = 1 ]; then ok "64-bit client usable" "loader and binary present"
elif [ "$have32" = 1 ]; then ok "32-bit client usable" "64-bit unavailable on this system"
else bad "no usable client" "no matching loader for either shipped binary"; fi
[ "$have64" = 0 ] && [ -f "$GAMEDIR/bin/mcpelauncher-client" ] &&
  warn "64-bit client cannot run here" "no aarch64 loader; an armeabi-v7a APK is required"

# The library loader is the honest test of "can this binary start at all".
client="$GAMEDIR/bin/mcpelauncher-client"
[ "$have64" = 1 ] || client="$GAMEDIR/bin32/mcpelauncher-client"
if command -v ldd >/dev/null 2>&1 && [ -f "$client" ]; then
  unresolved="$(LD_LIBRARY_PATH="$GAMEDIR/libs.aarch64:${LD_LIBRARY_PATH:-}" \
                ldd "$client" 2>/dev/null | sed -n 's/^[[:space:]]*\([^ ]*\) => not found/\1/p')"
  # The 64-bit path runs inside the Weston runtime, which is mounted only at
  # launch and supplies the X11/EGL/Wayland stack. Those showing as missing
  # here is expected and not a fault -- the reference RG34XX-SP reports
  # libX11.so.6 unresolved while running the game perfectly.
  from_weston="$(printf '%s\n' "$unresolved" |
                 grep -Ec 'lib(X11|xcb|Xau|Xdmcp|EGL|GLESv|wayland|xkbcommon|gbm|drm)' || true)"
  other="$(printf '%s\n' "$unresolved" | grep -c . || true)"
  other=$((other - from_weston))
  if [ "$other" -gt 0 ]; then
    bad "client libraries missing" "$(printf '%s' "$unresolved" | tr '\n' ' ')"
  elif [ "$from_weston" -gt 0 ]; then
    ok "client libraries resolve" "display libraries come from the Weston runtime at launch"
  else
    ok "client libraries resolve" ""
  fi
else
  warn "cannot check client libraries" "ldd is unavailable"
fi

# -------------------------------------------------------------------- runtime
head_ "runtimes"
pm=""
for cf in /opt/system/Tools/PortMaster /opt/tools/PortMaster \
          "${XDG_DATA_HOME:-$HOME/.local/share}/PortMaster" \
          /userdata/system/.local/share/PortMaster /storage/roms/ports/PortMaster \
          /roms/ports/PortMaster /roms/tools/PortMaster \
          /mnt/mmc/MUOS/PortMaster /mnt/sdcard/MUOS/PortMaster; do
  # Follow a stub control.txt to the tree that actually holds the runtimes.
  [ -f "$cf/control.txt" ] && { pm="$(mcpe_resolve_pm_root "$cf")"; break; }
done
[ -n "$pm" ] && ok "PortMaster found" "$pm" || bad "PortMaster control.txt not found" "the port cannot resolve device settings"

love=""
for lt in "$pm/runtimes/love_11.5/love.txt" "$pm/libs/love_11.5/love.txt" \
          "$pm/runtimes/love/love.txt"; do
  [ -f "$lt" ] && { love="$lt"; break; }
done
[ -n "$love" ] && ok "LOVE runtime present" "the launcher menu will work" ||
  warn "LOVE 11.5 runtime missing" "no menu; install it from PortMaster"

weston=""
for w in "$pm"/libs/weston_pkg_0.2* "$pm"/runtimes/weston_pkg_0.2*; do
  [ -f "$w" ] && { weston="$w"; break; }
done
if [ "$have64" = 1 ]; then
  [ -n "$weston" ] && ok "Weston runtime present" "$(basename "$weston")" ||
    warn "Weston runtime missing" "the 64-bit path downloads it on first launch"
fi

# ---------------------------------------------------------------------- audio
head_ "audio"
mcpe_resolve_audio >/dev/null 2>&1
ok "audio backend" "${MCPE_AUDIO_BACKEND_RESOLVED:-unknown} (SDL ${MCPE_SDL_AUDIODRIVER:-default}, OpenAL ${ALSOFT_DRIVERS:-default})"
[ -d /dev/snd ] || warn "no /dev/snd" "the device exposes no ALSA node"
if [ "${MCPE_HAS_PIPEWIRE:-0}" = 1 ] && ! mcpe_pipewire_client_usable; then
  warn "PipeWire has no client config" "OpenAL is pinned to ALSA to avoid a failing context"
fi

# ------------------------------------------------------------------- controls
head_ "controls"
pads="$(grep -c 'Handlers=.*js[0-9]' /proc/bus/input/devices 2>/dev/null || echo 0)"
case "$pads" in
  0) warn "no gamepad detected" "the port maps controls per pad; check the device is not asleep" ;;
  *) ok "gamepads detected" "$pads (run controller_diag.py for the mapping)" ;;
esac
[ "${MCPE_TOUCH_COUNT:-0}" -gt 0 ] && ok "touch input" "${MCPE_TOUCH_COUNT} node(s)"

# --------------------------------------------------------------------- storage
head_ "storage"
shared="${MCPE_SHARED_ROOT:-$(dirname "$GAMEDIR")/minecraftbedrock-data}"
for d in "$GAMEDIR" "$shared"; do
  [ -d "$d" ] || continue
  if [ -w "$d" ]; then ok "writable" "$d"; else bad "not writable" "$d"; fi
done
avail_kb="$(df -Pk "$GAMEDIR" 2>/dev/null | awk 'NR==2{print $4}')"
case "${avail_kb:-0}" in
  ''|*[!0-9]*) warn "free space unknown" "" ;;
  *)
    avail_mb=$((avail_kb / 1024))
    if [ "$avail_mb" -ge 2048 ]; then ok "free space" "${avail_mb} MB"
    elif [ "$avail_mb" -ge 700 ]; then warn "free space is tight" "${avail_mb} MB; a Bedrock install needs about 700 MB"
    else bad "not enough free space" "${avail_mb} MB; a Bedrock install needs about 700 MB"; fi ;;
esac

# -------------------------------------------------------------------- versions
head_ "installed Bedrock versions"
# One unusable extra version is not a broken device: the launcher simply will
# not select it. Only a complete absence of playable versions is a failure.
found=0; playable=0
for v in "$GAMEDIR"/versions/*/; do
  [ -d "$v" ] || continue
  case "$(basename "$v")" in .*) continue ;; esac
  found=$((found + 1))
  name="$(basename "$v")"
  env_out="$(python3 "$GAMEDIR/version_env.py" "$GAMEDIR" "$v" 2>/dev/null)" || env_out=""
  status="$(printf '%s\n' "$env_out" | sed -n "s/^MCPE_COMPAT_STATUS=//p" | tr -d \"\')"
  rec="$(printf '%s\n' "$env_out" | sed -n "s/^MCPE_RECOMMENDATION=//p" | tr -d \"\')"
  case "$status" in
    unsupported) warn "$name" "unsupported by the registry; the launcher will not select it" ;;
    "")          warn "$name" "no usable metadata; reinstall it from the menu" ;;
    *)           playable=$((playable + 1)); ok "$name" "$status${rec:+, $rec}" ;;
  esac
done
if [ "$found" = 0 ]; then
  warn "no Bedrock version installed" "install one from the menu before playing"
elif [ "$playable" = 0 ]; then
  bad "no playable Bedrock version" "all $found installed versions are unusable"
fi

# --------------------------------------------------------------------- ladder
head_ "failsafe ladder"
state="$GAMEDIR/config/launch_state.json"
if [ -s "$state" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$state" <<'PY' 2>/dev/null || warn "ladder state unreadable" ""
import json, sys
try:
    entries = json.load(open(sys.argv[1]))["entries"]
except Exception:
    raise SystemExit(1)
if not entries:
    print("[ ok ] failsafe ladder — no history yet")
for key, e in entries.items():
    rung = e.get("rung", 0)
    tag = "[ ok ]" if rung == 0 else "[warn]"
    print(f"{tag} failsafe rung {rung} — {key} (last: {e.get('last_outcome','none')})")
PY
else
  ok "failsafe ladder" "no history yet; the tuned profile will be used"
fi
prev="$(cut -f1 <"$GAMEDIR/logs/stage.prev.txt" 2>/dev/null)"
case "$prev" in
  ""|done) ;;
  *) warn "previous launch did not finish" "it stopped at '$prev'; see logs/hang-report.txt if present" ;;
esac

# -------------------------------------------------------------------- summary
say ""
say "summary: $PASS ok, $WARN warnings, $FAIL failures"
if [ "$FAIL" -gt 0 ]; then
  say "This device cannot run the port as configured. Include this report."
elif [ "$WARN" -gt 0 ]; then
  say "Playable, with the warnings above worth reporting if something misbehaves."
else
  say "Everything the port needs is present."
fi

rm -f "$GAMEDIR/logs/selftest-host.env" 2>/dev/null
[ "$FAIL" -gt 0 ] && exit 1
exit 0
}

# Run the checks once, redact the result, and show the same text that is saved.
# The report is what a reporter pastes into an issue, so it must be identical
# to what they saw and must not carry an address or a mail account.
raw="$(mcpe_selftest_main 2>&1)"
status=$?
# Bedrock versions look exactly like IPv4 addresses, so protect their dots
# before the address filter runs and restore them afterwards. Kept in step with
# copy_redacted() in create_support_bundle.sh.
printf '%s\n' "$raw" | sed -E \
  -e 's#([0-9]+)\.([0-9]+)\.([0-9]+)\.(0[0-9]+)#\1@D@\2@D@\3@D@\4#g' \
  -e 's#([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9]+-arm)#\1@D@\2@D@\3@D@\4\5#g' \
  -e 's#(https?://)[^/@[:space:]]+@#\1REDACTED@#g' \
  -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#REDACTED_EMAIL#g' \
  -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#REDACTED_IP#g' \
  -e 's#@D@#.#g' \
  | tee "$REPORT" 2>/dev/null || printf '%s\n' "$raw"
[ -s "$REPORT" ] && printf '\nSaved to %s\n' "$REPORT"
exit "$status"
