#!/usr/bin/env bash
# device_verify.sh — deploy the telemetry-enabled client to the
# RG34XX-SP and verify /dev/shm/mcpe_telemetry comes alive.
#
# SCOPE NOTE: the RG34XX-SP is a single-screen device and is NOT a
# target for any bottom-screen feature. This script uses it purely as a
# test mule for the in-process telemetry hook, because the current
# custom client build (H700/crusty EGLUT) only runs on that hardware.
# The real verification target is the RG DS once the port runs there.
#
# Run from WSL:  bash device_verify.sh [device_ip]
# Prereqs: device on + reachable (Knulli Scarab, root/linux),
#   eglut_build/mcpelauncher-client.arm64.telemetry staged (build of
#   2026-07-10, sha256 7ab26997dc55a1ae...),
#   /root/bedrockmap/telemetry_dump.arm64 built.
#
# SAFE: does NOT touch the production binary; uses BIN_OVERRIDE through
# the existing _weston_launch.sh test harness (see AGENT_HANDOFF.md §5).
# Do NOT run while someone is playing on the device.
#
# Expectations:
# - In the menu, frame metrics flow => fps>0, frames increasing.
# - `game` flag + position only go live IN-WORLD (FMOD 3D listener) —
#   entering a world needs a human; menu-only verifies the module loads,
#   shm appears, and frame stats tick.
set -e
IP=${1:-192.168.1.12}
SSH="sshpass -p linux ssh -o StrictHostKeyChecking=accept-new root@$IP"
LOCAL_BIN=/mnt/c/Programmering/SBC/RG34xxSP/Minecraft_Bedrock_PortMaster/eglut_build/mcpelauncher-client.arm64.telemetry
DUMP=/root/bedrockmap/telemetry_dump.arm64
PORTS=/userdata/roms/ports

echo "== deploy =="
sshpass -p linux scp -o StrictHostKeyChecking=accept-new \
    "$LOCAL_BIN" root@$IP:$PORTS/mcpe_eglut/mcpelauncher-client.telemetry
sshpass -p linux scp "$DUMP" root@$IP:$PORTS/mcpe_eglut/telemetry_dump
$SSH "chmod +x $PORTS/mcpe_eglut/mcpelauncher-client.telemetry $PORTS/mcpe_eglut/telemetry_dump"

echo "== timed launch (60s, menu is enough for frame metrics) =="
$SSH "rm -f /dev/shm/mcpe_telemetry; \
  export BIN_OVERRIDE=$PORTS/mcpe_eglut/mcpelauncher-client.telemetry; \
  export WP_32BIT_OVERRIDE=0; \
  cd $PORTS/mcpe_launcher && bash _weston_launch.sh 60 crusty_x11egl \
    >/tmp/telemetry_test.log 2>&1 &
  sleep 40; \
  echo '--- telemetry after 40s ---'; \
  ls -la /dev/shm/mcpe_telemetry 2>/dev/null || echo 'SHM MISSING'; \
  $PORTS/mcpe_eglut/telemetry_dump --once || true; \
  sleep 1; $PORTS/mcpe_eglut/telemetry_dump --once || true"

echo "== done; game exits at the 60s timeout, harness restores ES =="
echo "PASS = shm exists, fps>0, frames increases between the two dumps."
echo "Next (human): launch a world normally with BIN_OVERRIDE set and"
echo "watch pos/yaw track movement via telemetry_dump."
