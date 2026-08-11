#!/bin/sh
# terrain_loop.sh <worlds_dir> <binary_dir> [state_dir]
# Companion to bottomd. EVENT-DRIVEN (2026-07-11): Bedrock flushes chunk
# data to its LevelDB every ~5 s during play (measured on the RG DS), so
# instead of a fixed cycle we watch the active world's db for writes and
# run a bedrockmap pass right after each flush. Passes are cheap:
# bedrockmap's chunks.hash cache skips unchanged chunks (~0.3 s
# no-change pass on-device). An idle fallback pass every ~6 s keeps
# player.json fresh. bottomd picks tile changes up via mtime watch.
#
# End-to-end chunk latency = wait for the game's own flush (0-5 s) +
# ~1-2 s detect/snapshot/render/reload. Going faster than that needs an
# in-process save trigger (see handoff).
WORLDS="$1"
BS="$2"
STATE="${3:-$BS}"
[ -d "$BS" ] || exit 1
SNAP="${MCPE_DBSNAP:-/tmp/mcpe_dbsnap}"
CURRENT="$STATE/tiles_live/current"
WAYPOINTS="$STATE/waypoints"
mkdir -p "$CURRENT" "$WAYPOINTS"
LAST_SIG=""
LAST_WID=$(cat "$CURRENT/.world-id" 2>/dev/null || true)
IDLE=0
RADIUS=${BOTTOMD_TERRAIN_RADIUS_CHUNKS:-12}
case "$RADIUS" in
  ''|*[!0-9]*) RADIUS=12 ;;
esac
[ "$RADIUS" -ge 8 ] 2>/dev/null || RADIUS=8
[ "$RADIUS" -le 64 ] 2>/dev/null || RADIUS=64
HISTORY="$STATE/terrain-history.log"
MAP_SOURCE="$STATE/map-source"
LAST_MAP_SOURCE=""
PROC_ROOT=${MCPE_PROC_ROOT:-/proc}
GAME_PROC=""
FD_ACTIVE=""
ACTIVE=""
SELECT_TICKS=3

refresh_game_proc() {
  if [ -n "$GAME_PROC" ] && [ -r "$GAME_PROC/cmdline" ] &&
     tr '\000' ' ' < "$GAME_PROC/cmdline" 2>/dev/null |
       grep -q 'mcpelauncher-client'; then
    return 0
  fi
  GAME_PROC=""
  for candidate in "$PROC_ROOT"/[0-9]*; do
    [ -r "$candidate/cmdline" ] || continue
    if tr '\000' ' ' < "$candidate/cmdline" 2>/dev/null |
       grep -q 'mcpelauncher-client'; then
      GAME_PROC=$candidate
      return 0
    fi
  done
  return 1
}

active_from_game_fds() {
  FD_ACTIVE=""
  refresh_game_proc || return 1
  for descriptor in "$GAME_PROC"/fd/*; do
    target=$(readlink "$descriptor" 2>/dev/null) || continue
    case "$target" in
      "$WORLDS"/*/db/*)
        candidate=${target%/db/*}
        if [ -d "$candidate/db" ]; then
          FD_ACTIVE=$candidate
          return 0
        fi
        ;;
    esac
  done
  return 1
}

db_signature() {
  stat -c '%n:%s:%Y' "$ACTIVE/db"/*.log "$ACTIVE/db"/CURRENT \
    "$ACTIVE/db"/MANIFEST-* 2>/dev/null | md5sum
}

while true; do
  sleep 0.3
  SOURCE=$(cat "$MAP_SOURCE" 2>/dev/null || echo local)
  if [ "$SOURCE" != "$LAST_MAP_SOURCE" ]; then
    printf '%s map-source=%s\n' \
      "$(date -Iseconds 2>/dev/null || date)" "$SOURCE" >> "$HISTORY"
    LAST_MAP_SOURCE=$SOURCE
  fi
  # Remote clients receive chunks over RakNet but do not expose the host's
  # LevelDB. Never keep snapshotting the last local world in that state.
  # `unknown` is the safe startup/cleanup state until live telemetry decides.
  case "$SOURCE" in
    remote|unknown) sleep 1; continue ;;
  esac
  # Prefer the world database the game actually has open. Unlike write mtime,
  # this changes as soon as a world is loaded and does not wait for movement
  # to make LevelDB append. The newest log remains a best-effort fallback for
  # hosts that restrict /proc/<pid>/fd.
  SELECT_TICKS=$((SELECT_TICKS + 1))
  if [ "$SELECT_TICKS" -ge 3 ] || [ -z "$ACTIVE" ]; then
    SELECT_TICKS=0
    if active_from_game_fds; then
      ACTIVE=$FD_ACTIVE
    else
      ACTIVE_LOG=$(ls -1t "$WORLDS"/*/db/*.log 2>/dev/null | head -1)
      ACTIVE=${ACTIVE_LOG%/db/*}
    fi
  fi
  [ -n "$ACTIVE" ] && [ -d "$ACTIVE/db" ] || { sleep 2; continue; }

  WID=$(basename "$ACTIVE")
  if [ "$WID" != "$LAST_WID" ]; then
    # Keep the directory inode stable because bottomd watches this exact path.
    # Save per-world waypoints, clear only generated runtime content, and then
    # repopulate the same directory for the newly active world.
    OLD_WID=${LAST_WID:-$WID}
    [ -f "$CURRENT/waypoints.txt" ] &&
      cp "$CURRENT/waypoints.txt" "$WAYPOINTS/$OLD_WID.txt" 2>/dev/null || true
    for generated in "$CURRENT"/* "$CURRENT"/.[!.]* "$CURRENT"/..?*; do
      [ -e "$generated" ] || [ -L "$generated" ] || continue
      rm -rf "$generated"
    done
    if [ -f "$WAYPOINTS/$WID.txt" ]; then
      cp "$WAYPOINTS/$WID.txt" "$CURRENT/waypoints.txt"
    else
      : > "$CURRENT/waypoints.txt"
    fi
    printf '%s\n' "$WID" > "$CURRENT/.world-id"
    LAST_WID=$WID
    LAST_SIG=""
  fi

  # db write signature: names+sizes+mtimes of the write-side files
  SIG=$(db_signature)
  if [ "$SIG" = "$LAST_SIG" ]; then
    IDLE=$((IDLE + 1))
    [ "$IDLE" -lt 10 ] && continue # ~3 s idle fallback pass
  fi
  IDLE=0
  # let the game's write burst finish before snapshotting (a torn .log
  # copy just fails the pass open(); we retry on the next tick)
  sleep 0.4
  LAST_SIG=$(db_signature)

  rm -rf "$SNAP"
  mkdir -p "$SNAP"
  cp -r "$ACTIVE/db" "$SNAP/" 2>/dev/null || continue
  cp "$ACTIVE/level.dat" "$SNAP/" 2>/dev/null

  STARTED=$(date +%s)
  nice -n 10 "$BS/bedrockmap" --db "$SNAP/db" --out "$CURRENT" \
      --center-telemetry --radius-chunks "$RADIUS" > "$BS/terrain.log" 2>&1
  STATUS=$?
  FINISHED=$(date +%s)
  printf '%s world=%s radius=%s seconds=%s status=%s %s\n' \
    "$(date -Iseconds 2>/dev/null || date)" "$WID" "$RADIUS" \
    "$((FINISHED - STARTED))" "$STATUS" \
    "$(head -1 "$BS/terrain.log" 2>/dev/null)" >> "$HISTORY"
  if [ "$(wc -c < "$HISTORY" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 400 "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
  fi
done
