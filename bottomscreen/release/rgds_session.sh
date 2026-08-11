#!/bin/bash
# RGDS session: independent companion UI, native Sway placement, SELECT flip, OSK.

mcpe_rgds_signal_tree() {
  local signal="$1" parent="$2" child
  [ -n "$parent" ] || return 0
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    mcpe_rgds_signal_tree "$signal" "$child"
  done
  kill "-$signal" "$parent" 2>/dev/null || true
}

mcpe_rgds_stop() {
  [ "${RGDS_CLEANED_UP:-0}" = 0 ] || return 0
  RGDS_CLEANED_UP=1
  local pid i alive
  for pid in "${RGDS_GAME_PID:-}" "${RGDS_BOTTOMD_PID:-}" "${RGDS_TERRAIN_PID:-}" "${RGDS_OSK_PID:-}"; do
    mcpe_rgds_signal_tree TERM "$pid"
  done
  i=0
  while [ "$i" -lt 8 ]; do
    alive=0
    for pid in "${RGDS_GAME_PID:-}" "${RGDS_BOTTOMD_PID:-}" "${RGDS_TERRAIN_PID:-}" "${RGDS_OSK_PID:-}"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break
    sleep 1
    i=$((i + 1))
  done
  for pid in "${RGDS_GAME_PID:-}" "${RGDS_BOTTOMD_PID:-}" "${RGDS_TERRAIN_PID:-}" "${RGDS_OSK_PID:-}"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && mcpe_rgds_signal_tree KILL "$pid"
  done
  for pid in "${RGDS_GAME_PID:-}" "${RGDS_BOTTOMD_PID:-}" "${RGDS_TERRAIN_PID:-}" "${RGDS_OSK_PID:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  [ -x "$RGDS_DIR/osk_hide.sh" ] && "$RGDS_DIR/osk_hide.sh" >/dev/null 2>&1 || true
  if [ -s "${RGDS_INPUT_STATE:-}" ]; then
    python3 "$RGDS_DIR/input_state.py" restore "$RGDS_INPUT_STATE" >>"$GAMEDIR/logs/rgds-input.log" 2>&1 || true
  fi
  rm -f "${MCPE_TELEMETRY_SHM_PATH:-/dev/shm/mcpe_telemetry}" 2>/dev/null || true
  rm -f "${MCPE_COMPANION_STATE_SHM_PATH:-/dev/shm/mcpe_companion_state}" \
        "${MCPE_COMPANION_CMD_SHM_PATH:-/dev/shm/mcpe_companion_cmd}" \
        2>/dev/null || true
  command -v swaymsg >/dev/null 2>&1 && {
    swaymsg "[app_id=\"mcpelauncher-client\"] move container to output $RGDS_TOP_OUTPUT, fullscreen enable" >/dev/null 2>&1 || true
  }
  echo "RGDS companion session stopped and input state restored."
}

mcpe_rgds_start() {
  RGDS_DIR="$GAMEDIR/rgds"
  RGDS_GAME_PID=""; RGDS_BOTTOMD_PID=""; RGDS_TERRAIN_PID=""; RGDS_OSK_PID=""; RGDS_CLEANED_UP=0
  export RGDS_DIR RGDS_GAME_PID RGDS_BOTTOMD_PID RGDS_TERRAIN_PID RGDS_OSK_PID RGDS_CLEANED_UP
  [ "${MCPE_HOST_ARCH:-}" = aarch64 ] || { echo "RGDS edition requires aarch64 userspace." >&2; return 1; }
  [ "${MCPE_HOST_COMPOSITOR:-}" = sway ] || { echo "RGDS dual-screen mode requires Sway; this OS is experimental/unsupported." >&2; return 1; }
  command -v swaymsg >/dev/null 2>&1 || { echo "swaymsg is required for RGDS mode." >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required for RGDS discovery." >&2; return 1; }
  # BusyBox unzip may have discarded executable modes from older archives.
  # Normalize only the stable helpers shipped by this edition.
  chmod u+x "$RGDS_DIR/bottomd" "$RGDS_DIR/bedrockmap" \
    "$RGDS_DIR/terrain_loop.sh" "$RGDS_DIR/osk_show.sh" \
    "$RGDS_DIR/osk_hide.sh" "$RGDS_DIR/thor-keyboard.sh" 2>/dev/null || true
  [ -x "$RGDS_DIR/bottomd" ] && [ -x "$RGDS_DIR/bedrockmap" ] || { echo "RGDS companion binaries are missing." >&2; return 1; }

  if [ -z "${SWAYSOCK:-}" ] || [ -z "${WAYLAND_DISPLAY:-}" ]; then
    local sway_pid
    sway_pid="$(pidof sway 2>/dev/null | awk '{print $1}')"
    [ -n "$sway_pid" ] && while IFS= read -r line; do
      case "$line" in SWAYSOCK=*|XDG_RUNTIME_DIR=*|WAYLAND_DISPLAY=*) export "$line" ;; esac
    done < <(tr '\0' '\n' <"/proc/$sway_pid/environ" 2>/dev/null)
  fi
  # ROCKNIX's sway service exports XDG_RUNTIME_DIR but may omit SWAYSOCK and
  # WAYLAND_DISPLAY from /proc/<pid>/environ. PortMaster normally inherits
  # both, while SSH/support sessions do not. Resolve only sockets inside the
  # compositor's own runtime directory so remote diagnostics use the same
  # capability path without hardcoding a wayland or Sway socket number.
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -z "${SWAYSOCK:-}" ]; then
    local socket
    for socket in "$XDG_RUNTIME_DIR"/sway-ipc.*.sock; do
      [ -S "$socket" ] && { export SWAYSOCK="$socket"; break; }
    done
  fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    local socket
    for socket in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
      [ -S "$socket" ] && { export WAYLAND_DISPLAY="${socket##*/}"; break; }
    done
  fi
  [ -n "${SWAYSOCK:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] || {
    echo "RGDS could not resolve the active Sway/Wayland session sockets." >&2
    return 1
  }
  RGDS_INPUT_STATE="$GAMEDIR/runtime/rgds-input-state.json"
  export RGDS_INPUT_STATE
  python3 "$RGDS_DIR/input_state.py" save "$RGDS_INPUT_STATE" >>"$GAMEDIR/logs/rgds-input.log" 2>&1 || return 1

  local discovery
  if ! discovery="$(python3 "$RGDS_DIR/discover_rgds.py")"; then
    python3 "$RGDS_DIR/input_state.py" restore "$RGDS_INPUT_STATE" >>"$GAMEDIR/logs/rgds-input.log" 2>&1 || true
    return 1
  fi
  eval "$discovery"
  export RGDS_TOP_OUTPUT RGDS_BOTTOM_OUTPUT RGDS_TOP_WIDTH RGDS_TOP_HEIGHT RGDS_BOTTOM_WIDTH RGDS_BOTTOM_HEIGHT
  export RGDS_REGION_X RGDS_REGION_Y RGDS_REGION_W RGDS_REGION_H
  export MCPE_SWAY_OUTPUT="$RGDS_TOP_OUTPUT"
  export MCPE_DISPLAY_WIDTH="$RGDS_TOP_WIDTH" MCPE_DISPLAY_HEIGHT="$RGDS_TOP_HEIGHT"
  export BOTTOMD_TOP_OUTPUT="$RGDS_TOP_OUTPUT" BOTTOMD_BOTTOM_OUTPUT="$RGDS_BOTTOM_OUTPUT"
  export BOTTOMD_JOYPAD="$RGDS_GAMEPAD_EVENT"
  export BOTTOMD_PANEL_TOP="$RGDS_TOP_TOUCH_EVENT" BOTTOMD_PANEL_BOTTOM="$RGDS_BOTTOM_TOUCH_EVENT"
  # Chat and Items are independent native-bridge views. Framebuffer capture is
  # explicitly off: it cannot accidentally turn either page back into a game
  # mirror on an older client binary.
  export MCPE_MIRROR=0
  export MCPE_COMPANION=1
  export MCPE_COMPANION_STATE_SHM=/mcpe_companion_state
  export MCPE_COMPANION_CMD_SHM=/mcpe_companion_cmd
  export BOTTOMD_COMPANION_STATE_SHM="$MCPE_COMPANION_STATE_SHM"
  export BOTTOMD_COMPANION_CMD_SHM="$MCPE_COMPANION_CMD_SHM"
  export BOTTOMD_OSK_SHOW_CMD="$RGDS_DIR/osk_show.sh"
  export BOTTOMD_INJECT_TOUCH_ID="${MCPE_RGDS_INJECT_TOUCH_ID:-19779:20549:mcpe-rgds-touchinject}"
  rm -f /dev/shm/mcpe_mirror /dev/shm/mcpe_mirror_req \
        /dev/shm/mcpe_companion_state /dev/shm/mcpe_companion_cmd \
        2>/dev/null || true

  local resource_cache="$GAMEDIR/runtime/rgds-resources/$MCVER_OVERRIDE"
  mkdir -p "$resource_cache"
  if python3 "$RGDS_DIR/prepare_resources.py" \
      "$GAMEDIR/versions/$MCVER_OVERRIDE" "$resource_cache" \
      >>"$GAMEDIR/logs/rgds-resources.log" 2>&1; then
    export BOTTOMD_RESOURCE_INDEX="$resource_cache/resource-paths.txt"
    export BOTTOMD_ITEM_INDEX="$resource_cache/item-textures.tsv"
  else
    echo "RGDS could not index textures from the installed Minecraft version; using procedural UI fallback." >&2
  fi
  export BOTTOMD_BEDROCK_VERSION="$MCPE_BEDROCK_VERSION_NAME"

  swaymsg "output $RGDS_BOTTOM_OUTPUT enable" >/dev/null 2>&1 || true
  swaymsg "output $RGDS_BOTTOM_OUTPUT power on" >/dev/null 2>&1 || true
  swaymsg "for_window [app_id=\"bottomd\"] move container to output $RGDS_BOTTOM_OUTPUT, fullscreen enable" >/dev/null 2>&1 || true
  swaymsg "for_window [app_id=\"mcpelauncher-client\"] move container to output $RGDS_TOP_OUTPUT, fullscreen enable" >/dev/null 2>&1 || true
  # ROCKNIX already calibrates each physical touchscreen into its half of the
  # combined desktop. Both devices can share the same Sway identifier, so an
  # `input <identifier> map_to_region` command would alter both at once. Keep
  # native libinput calibration untouched; moving the game/bottomd surfaces is
  # sufficient for touch to follow every SELECT swap.

  if [ -x "$RGDS_DIR/osk_show.sh" ]; then
    export RGDS_THOR_WRAPPER="$RGDS_DIR/thor-keyboard.sh"
    export RGDS_OSK_OUTPUT="$RGDS_BOTTOM_OUTPUT"
    export OSK_STATE="$GAMEDIR/runtime/rgds-osk-state"
    export RGDS_THOR_KEYBOARD_DIR="${MCPE_RGDS_THOR_KEYBOARD_DIR:-/storage/thor-keyboard}"
    if [ -f "$RGDS_THOR_KEYBOARD_DIR/main.py" ]; then
      export MCPE_OSK_SHOW_CMD="$RGDS_DIR/osk_show.sh"
      export MCPE_OSK_HIDE_CMD="$RGDS_DIR/osk_hide.sh"
    else
      echo "RGDS OSK application not found at $RGDS_THOR_KEYBOARD_DIR; text entry will use the host fallback." >&2
    fi
  fi
  mkdir -p "$GAMEDIR/runtime/rgds-state/tiles_live/current"
  BOTTOMD_TILES="$GAMEDIR/runtime/rgds-state/tiles_live/current" \
  BOTTOMD_WAYPOINTS="$GAMEDIR/runtime/rgds-state/tiles_live/current/waypoints.txt" \
  BOTTOMD_MAP_SOURCE="$GAMEDIR/runtime/rgds-state/map-source" \
    "$RGDS_DIR/bottomd" --backend wayland --fps 20 >"$GAMEDIR/logs/bottomd.log" 2>&1 &
  RGDS_BOTTOMD_PID=$!
  MCPE_DBSNAP="${TMPDIR:-/tmp}/mcpe-dbsnap-$$" \
    sh "$RGDS_DIR/terrain_loop.sh" \
      "$MCPE_DATA_ROOT_OVERRIDE/mcpelauncher/games/com.mojang/minecraftWorlds" \
      "$RGDS_DIR" "$GAMEDIR/runtime/rgds-state" >"$GAMEDIR/logs/terrain.log" 2>&1 &
  RGDS_TERRAIN_PID=$!
  if [ -n "${MCPE_OSK_SHOW_CMD:-}" ] && [ -f "$RGDS_DIR/osk_supervisor.py" ]; then
    python3 -u "$RGDS_DIR/osk_supervisor.py" \
      --hide-cmd "$RGDS_DIR/osk_hide.sh" --state "$GAMEDIR/runtime/rgds-osk-state" \
      --log "$GAMEDIR/logs/osk-supervisor.log" >/dev/null 2>&1 &
    RGDS_OSK_PID=$!
  fi
  export RGDS_BOTTOMD_PID RGDS_TERRAIN_PID RGDS_OSK_PID
  trap 'mcpe_rgds_stop' EXIT
  trap 'mcpe_rgds_stop; exit 129' HUP
  trap 'mcpe_rgds_stop; exit 130' INT
  trap 'mcpe_rgds_stop; exit 143' TERM
  echo "RGDS companion started: top=$RGDS_TOP_OUTPUT bottom=$RGDS_BOTTOM_OUTPUT touches=$RGDS_TOUCH_COUNT gamepad=${RGDS_GAMEPAD_EVENT:-none}."
}
