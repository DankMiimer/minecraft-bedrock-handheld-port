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
exec bash "$GAMEDIR/launcher_entry.sh"
