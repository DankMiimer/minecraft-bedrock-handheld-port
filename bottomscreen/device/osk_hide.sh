#!/bin/sh
# osk_hide.sh — dismiss the on-screen keyboard (game closed its text
# field; run via MCPE_OSK_HIDE_CMD, or by osk_watchdog.py / osk_dismiss.sh
# when the game never got round to it). Stop the daemon entirely so its
# window unmaps and bottomd's minimap resurfaces, then hand focus back
# to the game window.
#
# This must be safe to run at ANY time, including when the keyboard is
# already down — it is the single uncover primitive that three different
# callers rely on (DUALSCREEN_RESEARCH_DB.md P5).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run/0-runtime-dir}"
export SWAYSOCK="${SWAYSOCK:-$XDG_RUNTIME_DIR/sway-ipc.0.sock}"
OSK_STATE="${OSK_STATE:-/tmp/mcpe_osk_state}"
RGDS_OSK_OUTPUT="${RGDS_OSK_OUTPUT:?RGDS_OSK_OUTPUT is required}"
RGDS_THOR_WRAPPER="${RGDS_THOR_WRAPPER:-/storage/thor-keyboard.sh}"

# Clear the state first: the watchdog treats a missing state file as
# "a normal hide happened, stand down", so it will not fire on top of us.
rm -f "$OSK_STATE" 2>/dev/null

[ -x "$RGDS_THOR_WRAPPER" ] || exit 0
bash "$RGDS_THOR_WRAPPER" stop >/dev/null 2>&1
swaymsg "[app_id=\"bottomd\"] move container to output $RGDS_OSK_OUTPUT, fullscreen enable" >/dev/null 2>&1
swaymsg '[app_id="mcpelauncher-client"] focus' >/dev/null 2>&1

# Belt and braces: if the keyboard window survived the stop (python
# wedged, SIGTERM lost) it would keep the panel covered — the exact
# failure this whole change exists to prevent. Kill it outright.
if swaymsg -t get_tree 2>/dev/null | grep -q "Thor Keyboard"; then
  pkill -f 'thor-keyboard' >/dev/null 2>&1
  sleep 0.3
  swaymsg "[app_id=\"bottomd\"] move container to output $RGDS_OSK_OUTPUT, fullscreen enable" >/dev/null 2>&1
fi
