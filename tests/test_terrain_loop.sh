#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORLDS="$TMP/worlds"
BS="$TMP/rgds"
STATE="$TMP/state"
mkdir -p "$WORLDS/old/db" "$WORLDS/new/db" "$BS" "$STATE/tiles_live/current"
printf old >"$WORLDS/old/db/world-name"
printf new >"$WORLDS/new/db/world-name"
printf current >"$WORLDS/old/db/CURRENT"
printf current >"$WORLDS/new/db/CURRENT"
printf log >"$WORLDS/old/db/000001.log"
sleep 1
printf log >"$WORLDS/new/db/000002.log"
printf '12,34,home\n' >"$STATE/tiles_live/current/waypoints.txt"
printf 'unknown\n' >"$STATE/map-source"
mkdir -p "$TMP/proc/123/fd"
printf 'mcpelauncher-client\0-dg\0test\0' >"$TMP/proc/123/cmdline"
ln -s "$WORLDS/old/db/000001.log" "$TMP/proc/123/fd/4"

cat >"$BS/bedrockmap" <<'EOF'
#!/bin/sh
DB=""; OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --db) DB=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --radius-chunks) printf '%s\n' "$2" >"$OUT/radius"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$OUT/0"
cat "$DB/world-name" >"$OUT/selected-world"
printf '{"x":0,"z":0}\n' >"$OUT/player.json"
EOF
chmod +x "$BS/bedrockmap"

# Startup and remote states must not render the most recently modified local
# DB. This is the LAN regression: without the gate the previous world's map is
# presented underneath live multiplayer coordinates.
MCPE_DBSNAP="$TMP/snapshot" MCPE_PROC_ROOT="$TMP/proc" timeout 2 \
  sh "$ROOT/bottomscreen/bottomd/terrain_loop.sh" "$WORLDS" "$BS" "$STATE" &
PAUSED_PID=$!
sleep 1
test ! -e "$STATE/tiles_live/current/selected-world"
printf 'remote\n' >"$STATE/map-source"
sleep 1
test ! -e "$STATE/tiles_live/current/selected-world"
kill "$PAUSED_PID" 2>/dev/null || true
wait "$PAUSED_PID" 2>/dev/null || true

printf 'local\n' >"$STATE/map-source"

MCPE_DBSNAP="$TMP/snapshot" MCPE_PROC_ROOT="$TMP/proc" timeout 4 \
  sh "$ROOT/bottomscreen/bottomd/terrain_loop.sh" "$WORLDS" "$BS" "$STATE" &
LOOP_PID=$!
for _ in $(seq 1 30); do
  [ -f "$STATE/tiles_live/current/selected-world" ] && break
  sleep 0.1
done
kill "$LOOP_PID" 2>/dev/null || true
wait "$LOOP_PID" 2>/dev/null || true

test "$(cat "$STATE/tiles_live/current/selected-world")" = old
test "$(cat "$STATE/tiles_live/current/radius")" = 12
test "$(cat "$STATE/tiles_live/current/.world-id")" = old
test "$(cat "$STATE/tiles_live/current/waypoints.txt")" = '12,34,home'
test ! -L "$STATE/tiles_live/current"
test ! -e "$STATE/tiles_live/current/new"
echo "terrain loop tests passed"
