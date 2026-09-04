#!/bin/bash
# Thin entrypoint for the separately versioned RGDS dual-screen edition.
set -u
ENTRY_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD=minecraftbedrock-rgds

find_payload() {
  local root parent
  for root in "$ENTRY_DIR/$PAYLOAD" \
              "/mnt/mmc/ports/$PAYLOAD" "/mnt/sdcard/ports/$PAYLOAD" \
              "/storage/ports/$PAYLOAD" "/roms/ports/$PAYLOAD" \
              "/userdata/roms/ports/$PAYLOAD"; do
    [ -f "$root/launcher_entry.sh" ] && { printf '%s\n' "$root"; return 0; }
  done
  parent="$(dirname "$ENTRY_DIR")"
  [ "$(basename "$ENTRY_DIR" | tr '[:upper:]' '[:lower:]')" = ports ] &&
    [ "$(basename "$parent" | tr '[:upper:]' '[:lower:]')" = roms ] && {
      root="$(dirname "$parent")/ports/$PAYLOAD"
      [ -f "$root/launcher_entry.sh" ] && { printf '%s\n' "$root"; return 0; }
    }
  return 1
}

GAMEDIR="$(find_payload)" || { echo "Minecraft Bedrock RGDS payload not found."; exit 1; }
export MCPE_PAYLOAD_NAME_OVERRIDE="$PAYLOAD"
export MCPE_GAMEDIR_OVERRIDE="$GAMEDIR"
export MCPE_ENTRY_DIR_OVERRIDE="$ENTRY_DIR"

# ROCKNIX launches ports below essway.service. Stopping that service from an
# ordinary child also kills the port with the rest of the service cgroup.
# Move the real launcher into its own transient scope first; scope mode keeps
# the caller's display/controller environment and waits for the game to exit.
# The scoped launcher can then stop ES-DE without stopping itself, while Sway
# remains in its separate service.
if [ "${MCPE_ROCKNIX_SCOPE:-0}" != 1 ] &&
   command -v systemd-run >/dev/null 2>&1 &&
   systemctl is-active --quiet essway.service 2>/dev/null; then
  unit="minecraft-bedrock-rgds-${PPID:-0}-$$"
  MCPE_ROCKNIX_SCOPE=1 \
    systemd-run --quiet --scope --collect --unit="$unit" \
      /bin/bash "$GAMEDIR/launcher_entry.sh"
  exit $?
fi

exec bash "$GAMEDIR/launcher_entry.sh"
