#!/usr/bin/env bash
# rgds_device_verify.sh — deploy and smoke-test the telemetry-enabled
# client on the Anbernic RG DS without replacing production files.
#
# Run from WSL:
#   bash bottomscreen/telemetry/rgds_device_verify.sh [ip] [version]
#
# The menu smoke test uses a temporary profile. It proves the telemetry module
# loads, creates /dev/shm/mcpe_telemetry, and publishes frame metrics. Position
# and yaw only become meaningful after a human enters a world.
set -euo pipefail

IP="${1:?usage: rgds_device_verify.sh <device-ip> [...]}"
MCVER="${2:-1.16.221.01}"
PASS="${RGDS_PASS:-rocknix}"
TEST_SECONDS="${RGDS_TELEMETRY_TEST_SECONDS:-75}"
SAMPLE_AFTER="${RGDS_TELEMETRY_SAMPLE_AFTER:-45}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_BIN="${LOCAL_BIN:-$REPO_ROOT/eglut_build/mcpelauncher-client.arm64.telemetry}"
DUMP="${DUMP:-/root/bedrockmap/telemetry_dump.arm64}"

REMOTE_GAME_DIR="/storage/roms/ports/minecraftbedrock"
REMOTE_BIN="$REMOTE_GAME_DIR/bin/mcpelauncher-client.telemetry"
REMOTE_DUMP="$REMOTE_GAME_DIR/bin/telemetry_dump"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
SSH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$IP")
SCP=(sshpass -p "$PASS" scp "${SSH_OPTS[@]}")

[ -f "$LOCAL_BIN" ] || {
  echo "missing telemetry client: $LOCAL_BIN" >&2
  exit 1
}
[ -f "$DUMP" ] || {
  echo "missing telemetry_dump aarch64 build: $DUMP" >&2
  exit 1
}

echo "== deploy telemetry artifacts to RG DS =="
"${SCP[@]}" "$LOCAL_BIN" "root@$IP:$REMOTE_BIN"
"${SCP[@]}" "$DUMP" "root@$IP:$REMOTE_DUMP"
"${SSH[@]}" "chmod +x '$REMOTE_BIN' '$REMOTE_DUMP' && sha256sum '$REMOTE_BIN' '$REMOTE_DUMP'"

echo "== timed menu launch with temporary profile =="
"${SSH[@]}" \
  "MCVER='$MCVER' TEST_SECONDS='$TEST_SECONDS' SAMPLE_AFTER='$SAMPLE_AFTER' sh -s" <<'REMOTE'
set -eu
GAMEDIR=/storage/roms/ports/minecraftbedrock
REMOTE_BIN="$GAMEDIR/bin/mcpelauncher-client.telemetry"
REMOTE_DUMP="$GAMEDIR/bin/telemetry_dump"
PROFILE=/tmp/mcpe_telemetry_profile
RUN_TMP=/tmp/run_bedrock.telemetry.sh
WESTON_TMP=/tmp/weston_launch.telemetry.sh
LAUNCH_LOG=/tmp/rgds_telemetry_launch.log
WESTON_LOG=/tmp/rgds_telemetry_weston_launch.log

[ -x "$REMOTE_BIN" ] || { echo "missing remote telemetry client"; exit 1; }
[ -x "$REMOTE_DUMP" ] || { echo "missing remote telemetry_dump"; exit 1; }
[ -d "$GAMEDIR/versions/$MCVER" ] || {
  echo "version not installed on RG DS: $MCVER"
  ls -1 "$GAMEDIR/versions" 2>/dev/null || true
  exit 1
}

if ps | grep -E '[m]cpelauncher-client|[l]ibminecraftpe' >/dev/null 2>&1; then
  echo "Minecraft already appears to be running; refusing to launch test."
  ps | grep -E '[m]cpelauncher-client|[l]ibminecraftpe' || true
  exit 1
fi

rm -f /dev/shm/mcpe_telemetry "$LAUNCH_LOG" "$WESTON_LOG" /tmp/rgds_telemetry_launch.rc
case "$PROFILE" in
  /tmp/mcpe_telemetry_profile) rm -rf "$PROFILE" ;;
  *) echo "refusing to remove unexpected profile path: $PROFILE"; exit 1 ;;
esac
mkdir -p "$PROFILE"

sed \
  -e 's#^export BIN_OVERRIDE=.*#export BIN_OVERRIDE="${MCPE_TEST_BIN_OVERRIDE:-$BIN64}"#' \
  -e 's#bash "$GAMEDIR/weston_launch.sh"#bash "/tmp/weston_launch.telemetry.sh"#' \
  "$GAMEDIR/run_bedrock.sh" > "$RUN_TMP"
sed \
  -e 's#^LOG=.*#LOG="/tmp/rgds_telemetry_weston_launch.log"#' \
  -e 's#^sway_touch_map$#:#' \
  "$GAMEDIR/weston_launch.sh" > "$WESTON_TMP"
chmod +x "$RUN_TMP" "$WESTON_TMP"

(
  export GAMEDIR
  export controlfolder=/storage/roms/ports/PortMaster
  export PM_DIR=PortMaster
  export MCVER_OVERRIDE="$MCVER"
  export MCPE_DATA_ROOT_OVERRIDE="$PROFILE"
  export MCPE_TEST_BIN_OVERRIDE="$REMOTE_BIN"
  export MCPE_TELEMETRY=1
  export MCPE_MEASURE_FPS=0
  export MCPE_PERFORMANCE_OPTIONS=0
  export MCPE_PREWARM_GAMEPLAY_ASSETS=0
  export TMO="$TEST_SECONDS"
  bash "$RUN_TMP" > "$LAUNCH_LOG" 2>&1
  echo "$?" >/tmp/rgds_telemetry_launch.rc
) &
launch_pid=$!

sleep "$SAMPLE_AFTER"
echo "--- telemetry after ${SAMPLE_AFTER}s ---"
ls -la /dev/shm/mcpe_telemetry 2>/dev/null || echo "SHM MISSING"
set +e
"$REMOTE_DUMP" --once > /tmp/rgds_telemetry_dump1.txt 2>&1
dump1_rc=$?
sleep 2
"$REMOTE_DUMP" --once > /tmp/rgds_telemetry_dump2.txt 2>&1
dump2_rc=$?
set -e
cat /tmp/rgds_telemetry_dump1.txt
cat /tmp/rgds_telemetry_dump2.txt
echo "dump_rc=$dump1_rc,$dump2_rc"

wait "$launch_pid" || true
echo "--- launch rc ---"
cat /tmp/rgds_telemetry_launch.rc 2>/dev/null || echo "no rc file"
echo "--- launch log tail ---"
tail -80 "$LAUNCH_LOG" 2>/dev/null || true
echo "--- weston log tail ---"
tail -80 "$WESTON_LOG" 2>/dev/null || true
REMOTE

echo "PASS = shm exists, dumps exit 0, fps is >0, and frames increases."
echo "In-world pos/yaw still needs a human to enter a world while this client is running."
