#!/bin/bash
# Make a launcher message visible on firmwares whose console is not.
#
# show_msg has always written to /dev/tty1. That is correct on the firmwares
# that bind fbcon to the panel, and it is the path the two reference devices
# use. muOS does not bind it: its only virtual console is the dummy driver and
# the kernel console is the serial port, so /dev/tty1 is writable and never
# rendered. Every message the launcher printed there was invisible, including
# the one telling a new player to install an APK -- which is what "the port
# shows a black screen and drops back to the menu" actually was.
#
# Measured on muOS 2601.0 (JACARANDA), RG34XX-SP, 2026-08-24:
#   /proc/consoles                ttyS0 only, no VT
#   /sys/class/vtconsole/*/name   "(S) dummy device", no framebuffer console
#   /dev/fb0                      720x480 visible, 720x960 virtual, 32bpp BGRA
#
# The ladder is: the console when it is real, then a LOVE frame, then painting
# the framebuffer directly. Each rung is only tried when the one above it is
# unavailable, so firmwares that already worked keep the exact path they had.

# True when a write to the active VT can reach the panel. Both probes must fail
# before we conclude otherwise, because being wrong here means drawing over a
# firmware that was rendering the console perfectly well.
# mcpe_meminfo_kb / mcpe_proc_ppid / mcpe_fb_geometry live in common.sh. Load it
# here too so this file stays usable on its own, the way platform.sh does.
if ! type mcpe_meminfo_kb >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

mcpe_console_is_visible() {
  # MCPE_PROBE_ROOT is honoured so the fixtures can assert both answers without
  # a device, the same way abi.sh and platform.sh do.
  local probe="${MCPE_PROBE_ROOT:-}" name
  # A numbered VT as a kernel console (tty0/tty1) means the panel shows it.
  # ttyS0 is a serial console and deliberately does not match.
  grep -qE '^tty[0-9]' "$probe/proc/consoles" 2>/dev/null && return 0
  for name in "$probe"/sys/class/vtconsole/vtcon*/name; do
    [ -r "$name" ] || continue
    case "$(cat "$name" 2>/dev/null)" in
      *'frame buffer device'*) return 0 ;;
    esac
  done
  return 1
}

# muOS keeps its frontend on the framebuffer, so anything drawn while it is up
# lands behind it. Stopping it is therefore required to show a message -- but
# frontend.sh is a supervisor that init starts and nothing respawns, so leaving
# it stopped is how a device ends up on a black screen until it is rebooted.
# Every stop below is paired with a restore, including on an interrupted draw.
MCPE_MSG_STOPPED_FRONTEND=0

# ...but a frontend.sh that is *waiting for this port* is not one of them. muOS
# runs a port from inside that same loop -- launch.sh starts the port script and
# the loop blocks until it returns -- so the supervisor is an ancestor of this
# process, and while it waits none of it is on the panel: muxlaunch exited
# before launch.sh ran. Stopping it therefore hides nothing, and the paired
# restore starts a *second* frontend that draws over the port and takes its
# input, which is exactly what appeared beside the Google sign-in window. Leave
# it alone; muOS returns to its own menu when the port exits.
mcpe_msg_frontend_awaits_us() {
  local probe="${MCPE_PROBE_ROOT:-}" pid="${MCPE_PROBE_PID:-$$}" hops=0 parent
  while [ "$hops" -lt 32 ]; do
    [ -r "$probe/proc/$pid/comm" ] || return 1
    [ "$(cat "$probe/proc/$pid/comm" 2>/dev/null)" = frontend.sh ] && return 0
    parent="$(mcpe_proc_ppid "$probe/proc/$pid/status" 2>/dev/null)"
    case "$parent" in ''|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid="$parent"
    hops=$((hops + 1))
  done
  return 1
}

mcpe_msg_quiet_frontend() {
  MCPE_MSG_STOPPED_FRONTEND=0
  mcpe_is_cfw muos || return 0
  mcpe_msg_frontend_awaits_us && return 0
  pidof frontend.sh >/dev/null 2>&1 || pidof muxplore >/dev/null 2>&1 ||
    pidof muxlaunch >/dev/null 2>&1 || return 0
  MCPE_MSG_STOPPED_FRONTEND=1
  ${ESUDO:-} killall -q frontend.sh muxplore muxlaunch 2>/dev/null || true
  sleep 1
}

mcpe_msg_restore_frontend() {
  [ "${MCPE_MSG_STOPPED_FRONTEND:-0}" = 1 ] || return 0
  MCPE_MSG_STOPPED_FRONTEND=0
  (
    unset GAMEDIR MCVER_OVERRIDE MCPE_DATA_ROOT_OVERRIDE MCPE_IS_MUOS MCPE_CFW
    if [ -x /opt/muos/script/mux/frontend.sh ]; then
      setsid /opt/muos/script/mux/frontend.sh launcher </dev/null >/dev/null 2>&1 &
    elif command -v frontend.sh >/dev/null 2>&1; then
      setsid frontend.sh launcher </dev/null >/dev/null 2>&1 &
    fi
  )
}

# Write the message lines to a file rather than passing player-visible text
# through argv, which has to survive the launch chain's quoting.
mcpe_msg_write_file() {
  local target="$1"; shift
  : > "$target" 2>/dev/null || return 1
  printf '%s\n' "$@" >> "$target" 2>/dev/null || return 1
}

mcpe_msg_love() {
  [ "${MCPE_MSG_LOVE:-1}" = 1 ] || return 1
  [ -n "${MCPE_MSG_LOVE_TXT:-}" ] && [ -f "${MCPE_MSG_LOVE_TXT}" ] || return 1
  [ -d "${GAMEDIR:-}/menu/msgbox" ] || return 1
  local msgfile="${MCPE_MSG_SCRATCH:-${GAMEDIR}/logs}/message.txt"
  mcpe_msg_write_file "$msgfile" "$@" || return 1
  local status=0
  mcpe_msg_quiet_frontend
  trap 'mcpe_msg_restore_frontend' INT TERM
  (
    # shellcheck disable=SC1090
    source "$MCPE_MSG_LOVE_TXT" 2>/dev/null || exit 1
    [ -n "${LOVE_RUN:-}" ] || exit 1
    MCPE_MSG_FILE="$msgfile" \
    MCPE_MSG_HEADING="${MCPE_MSG_HEADING:-Minecraft Bedrock}" \
    MCPE_MSG_TIMEOUT="${SHOW_MSG_SLEEP:-12}" \
    $LOVE_RUN "$GAMEDIR/menu/msgbox" >/dev/null 2>&1
  ) || status=1
  trap - INT TERM
  mcpe_msg_restore_frontend
  return "$status"
}

# Last resort: render the lines to raw pixels and write them straight to the
# framebuffer. No compositor, no runtime, nothing but the panel -- so this is
# what is left when LOVE is missing, which is exactly the case where a player
# most needs to be told something.
mcpe_msg_framebuffer() {
  [ "${MCPE_MSG_FRAMEBUFFER:-1}" = 1 ] || return 1
  [ -w /dev/fb0 ] || return 1
  command -v convert >/dev/null 2>&1 || return 1
  local font="${GAMEDIR:-}/menu/font_testo.ttf"
  [ -f "$font" ] || return 1

  local geometry width height virtual_height
  geometry="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)" || return 1
  width="${geometry%%,*}"
  virtual_height="${geometry##*,}"
  case "$width$virtual_height" in ''|*[!0-9]*) return 1 ;; esac
  # virtual_size is taller than the panel wherever the driver double-buffers
  # (720x960 for a 720x480 panel on H700), so take the visible height from
  # fbset and fall back to the virtual one only when fbset is absent.
  height="$(mcpe_fb_geometry | { read -r _ h _ _; printf '%s
' "${h:-}"; })"
  case "${height:-}" in ''|*[!0-9]*) height="$virtual_height" ;; esac

  local scratch="${MCPE_MSG_SCRATCH:-${TMPDIR:-/tmp}}/mcpe-msg.$$.bgra"
  local args=() y line
  y=$(( height / 5 ))
  args+=(-font "$font" -pointsize $(( height * 5 / 96 )) -fill '#7FDB6A')
  args+=(-annotate "+$(( width / 14 ))+${y}" "${MCPE_MSG_HEADING:-Minecraft Bedrock}")
  y=$(( y + height * 8 / 96 ))
  args+=(-fill '#EEEEEE' -pointsize $(( height * 4 / 96 )))
  for line in "$@"; do
    y=$(( y + height * 6 / 96 ))
    args+=(-annotate "+$(( width / 14 ))+${y}" "$line")
  done

  convert -size "${width}x${height}" xc:'#0A0F17' "${args[@]}" \
          -depth 8 "bgra:$scratch" 2>/dev/null || { rm -f "$scratch"; return 1; }

  mcpe_msg_quiet_frontend
  trap 'mcpe_msg_restore_frontend' INT TERM
  # Fill the whole virtual surface so the message shows whichever buffer the
  # driver happens to be scanning out.
  local repeats i
  repeats=$(( virtual_height / height ))
  [ "$repeats" -ge 1 ] 2>/dev/null || repeats=1
  i=0
  while [ "$i" -lt "$repeats" ]; do
    cat "$scratch" || break
    i=$(( i + 1 ))
  done > /dev/fb0 2>/dev/null
  rm -f "$scratch"
  sleep "${SHOW_MSG_SLEEP:-6}"
  trap - INT TERM
  mcpe_msg_restore_frontend
  return 0
}
