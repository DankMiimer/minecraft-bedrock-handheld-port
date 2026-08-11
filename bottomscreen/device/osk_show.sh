#!/bin/sh
# osk_show.sh — bring up the Thor/RGDS on-screen keyboard on the bottom
# panel. Run by mcpelauncher-client (MCPE_OSK_SHOW_CMD) when the game
# opens a text field. The keyboard daemon starts hidden, so: start
# (idempotent), unhide (SIGUSR2), then place it on the discovered panel.
# Keystrokes reach the game via uinput -> nested weston, independent of
# sway focus. While visible the keyboard EVIOCGRABs the bottom panel,
# so bottomd receives no stray touches.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run/0-runtime-dir}"
export SWAYSOCK="${SWAYSOCK:-$XDG_RUNTIME_DIR/sway-ipc.0.sock}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export SDL_VIDEODRIVER=wayland

BS="$(cd "$(dirname "$0")" && pwd)"
OSK_STATE="${OSK_STATE:-/tmp/mcpe_osk_state}"
RGDS_OSK_OUTPUT="${RGDS_OSK_OUTPUT:?RGDS_OSK_OUTPUT is required}"
RGDS_THOR_WRAPPER="${RGDS_THOR_WRAPPER:-/storage/thor-keyboard.sh}"

[ -x "$RGDS_THOR_WRAPPER" ] || exit 0

# Record WHY the cover went up and when, so the watchdog (and a human
# reading the log after a stuck screen) can tell an orphaned cover from
# a live one. P5: the cover must be attributable.
{
  echo "shown_at_monotonic=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  echo "shown_at_epoch=$(date +%s 2>/dev/null)"
  echo "reason=${MCPE_OSK_REASON:-game showKeyboard}"
  echo "pid_shell=$$"
} > "$OSK_STATE" 2>/dev/null

bash "$RGDS_THOR_WRAPPER" start >/dev/null 2>&1
# wait for the SDL window to map (it maps even while hidden) —
# python+SDL cold start needs several seconds on the RK3568;
# fullscreening before it maps silently matches nothing and the
# keyboard stays buried behind fullscreen bottomd
for _i in $(seq 1 20); do
  swaymsg -t get_tree 2>/dev/null | grep -q "Thor Keyboard" && break
  sleep 0.4
done
# for_window rule: the keyboard window can remap (the app manages its
# SDL window across hide/show) — the rule re-fullscreens it on EVERY
# map, immune to ordering. Runtime-idempotent; also installed at game
# launch by run_bedrock.sh.
swaymsg "for_window [title=\"^Thor Keyboard\"] move container to output $RGDS_OSK_OUTPUT, fullscreen enable" >/dev/null 2>&1
# NEVER focus the keyboard: keys ride uinput->weston-evdev and its touch
# uses compositor-routed touch, so focus is unnecessary — focusing it blanks
# the game (softlock 2026-07-12)
swaymsg "[title=\"^Thor Keyboard\"] move container to output $RGDS_OSK_OUTPUT, fullscreen enable" >/dev/null 2>&1
swaymsg '[app_id="mcpelauncher-client"] focus' >/dev/null 2>&1
swaymsg "output $RGDS_OSK_OUTPUT power on" >/dev/null 2>&1
# show AFTER the window is fullscreen: the visible-transition redraw
# then happens at final geometry. (The wrapper's show blocks until the
# daemon's handlers are installed — signaling earlier kills python:
# 2026-07-12 softlock.)
bash "$RGDS_THOR_WRAPPER" show >/dev/null 2>&1
# re-assert in case the show remapped the window (rule catches it too)
sleep 0.5
swaymsg "[title=\"^Thor Keyboard\"] move container to output $RGDS_OSK_OUTPUT, fullscreen enable" >/dev/null 2>&1

# Arm the independent uncover owner. hideKeyboard is NOT allowed to be
# the only thing that can give the bottom screen back (P5). One
# watchdog per show cycle; it exits by itself when osk_hide.sh runs.
if [ -x "$BS/osk_watchdog.py" ] || [ -f "$BS/osk_watchdog.py" ]; then
  pkill -f 'osk_watchdog\.py' >/dev/null 2>&1
  OSK_STATE="$OSK_STATE" setsid python3 -u "$BS/osk_watchdog.py" \
      --hide-cmd "$BS/osk_hide.sh" --state "$OSK_STATE" \
      >> "${OSK_LOG:-$BS/osk.log}" 2>&1 &
fi
