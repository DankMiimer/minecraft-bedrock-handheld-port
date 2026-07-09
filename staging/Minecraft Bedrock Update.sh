#!/bin/bash
# Minecraft Bedrock port — self-updater.
# Downloads the latest release from GitHub and updates the port's scripts,
# binaries, and menu IN PLACE. Never touches your installed game versions,
# worlds/profiles, or APKs. Needs WiFi.
#
# The whole script runs from main() so that overwriting this file mid-update
# cannot corrupt the running copy.

UPDATE_REPO="${MCPE_UPDATE_REPO:-DankMiimer/minecraft-bedrock-handheld-port}"

main() {
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

  # --- Locate the game dir (same candidates as the main entry) ---------------
  try_game_dir() {
    [ -f "$1/run_bedrock.sh" ] && [ -f "$1/setup_apk.sh" ] &&
      { echo "$1"; return 0; }
    return 1
  }
  GAMEDIR=""
  for c in "$SCRIPT_DIR/minecraftbedrock" \
           "/mnt/mmc/ports/minecraftbedrock" \
           "/mnt/sdcard/ports/minecraftbedrock" \
           "/storage/ports/minecraftbedrock" \
           "/roms/ports/minecraftbedrock" \
           "/userdata/roms/ports/minecraftbedrock"; do
    GAMEDIR="$(try_game_dir "$c")" && break
  done
  # Same roms/ports-parent fallback as the launch entries: a script in
  # <root>/roms/ports finds the payload at <root>/ports/minecraftbedrock.
  if [ -z "$GAMEDIR" ]; then
    base="$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]')"
    pbase="$(basename "$(dirname "$SCRIPT_DIR")" | tr '[:upper:]' '[:lower:]')"
    if [ "$base" = "ports" ] && [ "$pbase" = "roms" ]; then
      root="$(dirname "$(dirname "$SCRIPT_DIR")")"
      for c in "$root/ports/minecraftbedrock" "$root/Ports/minecraftbedrock"; do
        GAMEDIR="$(try_game_dir "$c")" && break
      done
    fi
  fi
  [ -n "$GAMEDIR" ] || { show_msg "Update failed:" "minecraftbedrock folder not found."; exit 1; }

  LOG="$GAMEDIR/update.log"
  : > "$LOG"
  exec > >(tee "$LOG") 2>&1
  echo "Update: script dir $SCRIPT_DIR, game dir $GAMEDIR"

  CUR="$(cat "$GAMEDIR/PORT_VERSION" 2>/dev/null || echo unknown)"

  # --- Fetch latest release metadata -----------------------------------------
  fetch() { # url [outfile]
    if command -v curl >/dev/null 2>&1; then
      if [ -n "${2:-}" ]; then curl -fsSL -o "$2" "$1"; else curl -fsSL "$1"; fi
    elif command -v wget >/dev/null 2>&1; then
      if [ -n "${2:-}" ]; then wget -q -O "$2" "$1"; else wget -q -O - "$1"; fi
    else
      return 127
    fi
  }

  show_msg "Checking for updates..." "Installed: $CUR"
  API_JSON="$(fetch "https://api.github.com/repos/$UPDATE_REPO/releases/latest")" || {
    show_msg "Update check failed." "Is WiFi connected?"
    exit 1
  }
  LATEST_TAG="$(printf '%s' "$API_JSON" | grep -o '"tag_name"[^,]*' | head -1 |
                sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/')"
  LATEST="${LATEST_TAG#v}"
  # The release zip. Old releases also published a -muos-sdroot variant;
  # skip it (the overlay below re-places files itself).
  ZIP_URL="$(printf '%s' "$API_JSON" |
             grep -o '"browser_download_url"[^,]*minecraftbedrock-[0-9][^"]*\.zip"' |
             grep -v 'muos-sdroot' | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')"
  [ -n "$LATEST" ] && [ -n "$ZIP_URL" ] || {
    show_msg "Update check failed:" "could not read the latest release info."
    exit 1
  }

  if [ "$CUR" = "$LATEST" ]; then
    show_msg "Already up to date (version $CUR)."
    exit 0
  fi

  # --- Download + verify ------------------------------------------------------
  show_msg "Updating $CUR -> $LATEST" "Downloading (about 10 MB)..."
  TMPD="$GAMEDIR/.update_tmp"
  rm -rf "$TMPD"; mkdir -p "$TMPD"
  fetch "$ZIP_URL" "$TMPD/update.zip" || {
    show_msg "Download failed." "Check WiFi and try again."
    rm -rf "$TMPD"; exit 1
  }
  unzip -t "$TMPD/update.zip" >/dev/null 2>&1 || {
    show_msg "Downloaded file is corrupt." "Try again."
    rm -rf "$TMPD"; exit 1
  }
  unzip -q -o "$TMPD/update.zip" -d "$TMPD/new" || {
    show_msg "Could not extract the update."
    rm -rf "$TMPD"; exit 1
  }
  # v1.5+ zips extract at the SD root (payload under ports/, scripts under
  # ports/ and roms/ports/); older zips had both at the zip root.
  if [ -d "$TMPD/new/ports/minecraftbedrock" ]; then
    NEW_PAYLOAD="$TMPD/new/ports/minecraftbedrock"
    NEW_SCRIPTS="$TMPD/new/ports"
  elif [ -d "$TMPD/new/minecraftbedrock" ]; then
    NEW_PAYLOAD="$TMPD/new/minecraftbedrock"
    NEW_SCRIPTS="$TMPD/new"
  else
    show_msg "Unexpected update layout - aborting."
    rm -rf "$TMPD"; exit 1
  fi

  # --- Overlay ---------------------------------------------------------------
  # Payload: copy the new minecraftbedrock/ contents over the install. The
  # release zip never contains versions/, profiles/, or user APKs, so a merge
  # copy cannot touch user data.
  cp -rf "$NEW_PAYLOAD/." "$GAMEDIR/" || {
    show_msg "Update copy FAILED - install may be partial." \
             "Re-extract the release zip manually."
    rm -rf "$TMPD"; exit 1
  }
  # Launch entries: new/renamed .sh files land beside this script. This file
  # itself is replaced LAST (script is fully parsed, so this is safe).
  for sh in "$NEW_SCRIPTS/"*.sh; do
    [ -f "$sh" ] || continue
    case "$(basename "$sh")" in "$(basename "$0")") continue ;; esac
    cp -f "$sh" "$SCRIPT_DIR/" && chmod +x "$SCRIPT_DIR/$(basename "$sh")"
  done
  [ -f "$NEW_SCRIPTS/$(basename "$0")" ] &&
    cp -f "$NEW_SCRIPTS/$(basename "$0")" "$SCRIPT_DIR/$(basename "$0")" &&
    chmod +x "$SCRIPT_DIR/$(basename "$0")"
  chmod +x "$GAMEDIR"/*.sh 2>/dev/null

  echo "$LATEST" > "$GAMEDIR/PORT_VERSION"
  rm -rf "$TMPD"
  show_msg "Updated to $LATEST." \
           "Your worlds, settings, and installed" \
           "game versions were not touched."
  exit 0
}

# On-screen messaging (same behavior as the main entry): fbdev CFWs show
# tty1 while a port runs; elsewhere the message goes to the log only.
show_msg() {
  echo "$*"
  if ! pidof sway >/dev/null 2>&1 && [ -w /dev/tty1 ]; then
    {
      clear
      echo
      echo "  ============ MINECRAFT BEDROCK UPDATE ============"
      echo
      printf '  %s\n' "$@"
      echo
      echo "  =================================================="
    } > /dev/tty1 2>/dev/null
    sleep 5
  fi
}

main "$@"
exit
