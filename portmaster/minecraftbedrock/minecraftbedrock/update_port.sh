#!/bin/bash
# Edition-aware, checksummed, atomic updater/installer (schema 2).
set -u
UPDATER_SCHEMA=2
UPDATE_REPO="${MCPE_UPDATE_REPO:-DankMiimer/minecraft-bedrock-handheld-port}"
INDEX_URL="${MCPE_RELEASE_INDEX_URL:-https://raw.githubusercontent.com/$UPDATE_REPO/main/release-index.json}"

show_msg() {
  echo "$*"
  if ! pidof sway >/dev/null 2>&1 && [ -w /dev/tty1 ]; then
    { clear; echo; echo "  ===== MINECRAFT BEDROCK UPDATE ====="; printf '  %s\n' "$@"; echo; } >/dev/tty1 2>/dev/null
    sleep 4
  fi
}

fail() { show_msg "Update failed:" "$*"; exit 1; }

GAMEDIR="${MCPE_GAMEDIR:-$(cd "$(dirname "$0")" && pwd)}"
[ -f "$GAMEDIR/lib/common.sh" ] || fail "common runtime helper is missing"
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh"
mcpe_load_edition "$GAMEDIR/edition.json" || fail "invalid current edition manifest"

TARGET_EDITION="${MCPE_UPDATE_TARGET_EDITION:-$MCPE_EDITION_ID}"
case "$TARGET_EDITION" in
  minecraftbedrock.standard) TARGET_PAYLOAD=minecraftbedrock; TARGET_ENTRY="Minecraft Bedrock.sh" ;;
  minecraftbedrock.rgds) TARGET_PAYLOAD=minecraftbedrock-rgds; TARGET_ENTRY="Minecraft Bedrock RGDS.sh" ;;
  *) fail "unknown target edition: $TARGET_EDITION" ;;
esac

TARGET_DIR="$(dirname "$GAMEDIR")/$TARGET_PAYLOAD"
if [ "$TARGET_EDITION" = "$MCPE_EDITION_ID" ]; then TARGET_DIR="$GAMEDIR"; fi
CHANNEL_FILE="$TARGET_DIR/config/update_channel"
settings_channel() {
  local settings="$1/config/settings.cfg"
  [ -f "$settings" ] || return 1
  sed -n 's/^update_channel=//p' "$settings" | tail -1
}
if [ -n "${MCPE_UPDATE_CHANNEL:-}" ]; then
  CHANNEL="$MCPE_UPDATE_CHANNEL"
elif [ -s "$CHANNEL_FILE" ]; then
  CHANNEL="$(cat "$CHANNEL_FILE")"
elif [ "$TARGET_EDITION" = "$MCPE_EDITION_ID" ]; then
  CHANNEL="$(settings_channel "$TARGET_DIR" || echo stable)"
else
  # A newly installed edition starts on stable. Its channel is independent
  # from whichever edition initiated the install.
  CHANNEL=stable
fi
case "$CHANNEL" in stable|testing) ;; *) fail "invalid update channel: $CHANNEL" ;; esac

# Legacy 1.x packages kept user data inside the code directory. Complete that
# independently recoverable migration before moving any code so the rollback
# tree and the replacement payload can both point at the same shared data.
# This is deliberately separate from the code swap transaction below.
if [ "$TARGET_EDITION" = "$MCPE_EDITION_ID" ] && [ "$TARGET_DIR" = "$GAMEDIR" ]; then
  [ -f "$GAMEDIR/lib/migrate_data.sh" ] || fail "shared-data migration helper is missing"
  # shellcheck disable=SC1091
  source "$GAMEDIR/lib/migrate_data.sh" || fail "could not load shared-data migration helper"
  mcpe_migrate_shared_data || fail "shared-data migration failed; code was not changed"
fi

PARENT="$(dirname "$TARGET_DIR")"
WORK="$PARENT/.${TARGET_PAYLOAD}.update-$$"
ROLLBACK="$PARENT/.${TARGET_PAYLOAD}.rollback"
cleanup() { [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
mkdir -p "$WORK" || fail "cannot create update staging directory"

show_msg "Checking $TARGET_EDITION ($CHANNEL)..."
mcpe_fetch "$INDEX_URL" "$WORK/release-index.json" || fail "could not download the release index; check WiFi"
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required to validate the release index"
SELECTED="$(python3 "$GAMEDIR/release_select.py" "$WORK/release-index.json" "$TARGET_EDITION" "$CHANNEL" 2>&1)" || fail "$SELECTED"
eval "$SELECTED"
[ "${RELEASE_MINIMUM_UPDATER:-99}" -le "$UPDATER_SCHEMA" ] || fail "this release requires a newer updater"

CURRENT="$(cat "$TARGET_DIR/PORT_VERSION" 2>/dev/null || echo none)"
if [ "$CURRENT" = "$RELEASE_VERSION" ]; then
  show_msg "$TARGET_EDITION is already $CURRENT ($CHANNEL)."
  exit 0
fi

show_msg "Downloading $RELEASE_ASSET" "$CURRENT -> $RELEASE_VERSION"
mcpe_fetch "$RELEASE_URL" "$WORK/update.zip" || fail "download failed"
[ "$(wc -c <"$WORK/update.zip" | tr -d ' ')" = "$RELEASE_SIZE" ] || fail "download size does not match the release index"
ACTUAL_HASH="$(mcpe_sha256 "$WORK/update.zip")" || fail "no SHA-256 implementation is available"
[ "$(printf '%s' "$ACTUAL_HASH" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$RELEASE_SHA256" | tr '[:upper:]' '[:lower:]')" ] || fail "download checksum does not match the release index"
unzip -t "$WORK/update.zip" >/dev/null 2>&1 || fail "downloaded archive is corrupt"
mcpe_archive_is_safe "$WORK/update.zip" || fail "archive contains an unsafe path"
mkdir "$WORK/extract" && unzip -q "$WORK/update.zip" -d "$WORK/extract" || fail "archive extraction failed"

NEW_PAYLOAD="$WORK/extract/ports/$TARGET_PAYLOAD"
[ -d "$NEW_PAYLOAD" ] || fail "archive does not contain ports/$TARGET_PAYLOAD"
[ -f "$NEW_PAYLOAD/edition.json" ] || fail "new payload has no edition manifest"
NEW_ID="$(mcpe_json_string "$NEW_PAYLOAD/edition.json" id)"
[ "$NEW_ID" = "$TARGET_EDITION" ] || fail "wrong-edition archive: expected $TARGET_EDITION, got $NEW_ID"
[ -f "$WORK/extract/ports/$TARGET_ENTRY" ] || fail "archive is missing $TARGET_ENTRY"

# Preserve only edition-owned mutable state. Shared APKs/worlds/versions live
# outside TARGET_DIR and therefore cannot be touched by this swap.
PERSIST="$WORK/persist"
mkdir "$PERSIST"
if [ -d "$TARGET_DIR" ]; then
  for item in config runtime logs fmod; do
    [ -e "$TARGET_DIR/$item" ] && mv "$TARGET_DIR/$item" "$PERSIST/$item"
  done
  [ -e "$ROLLBACK" ] && rm -rf "$ROLLBACK"
  mv "$TARGET_DIR" "$ROLLBACK" || fail "could not create rollback copy"
fi

if ! mv "$NEW_PAYLOAD" "$TARGET_DIR"; then
  [ -d "$ROLLBACK" ] && mv "$ROLLBACK" "$TARGET_DIR"
  for item in config runtime logs fmod; do [ -e "$PERSIST/$item" ] && mv "$PERSIST/$item" "$TARGET_DIR/$item"; done
  fail "could not activate the new payload"
fi

for item in config runtime logs fmod; do
  [ -e "$PERSIST/$item" ] || continue
  if [ -e "$TARGET_DIR/$item" ]; then
    cp -a "$PERSIST/$item/." "$TARGET_DIR/$item/" || true
    rm -rf "$PERSIST/$item"
  else
    mv "$PERSIST/$item" "$TARGET_DIR/$item"
  fi
done

# A migrated install has only symlinks at these legacy paths. Reproduce those
# links in the new payload without reading, copying, or modifying shared data;
# the rollback code retains its own links to the same edition-neutral root.
if [ -d "$ROLLBACK" ]; then
  for item in apk versions profiles backups; do
    [ -L "$ROLLBACK/$item" ] || continue
    if [ -d "$TARGET_DIR/$item" ] && mcpe_is_empty_dir "$TARGET_DIR/$item"; then
      rmdir "$TARGET_DIR/$item" 2>/dev/null || true
    fi
    [ ! -e "$TARGET_DIR/$item" ] && [ ! -L "$TARGET_DIR/$item" ] || continue
    cp -a "$ROLLBACK/$item" "$TARGET_DIR/$item" || {
      rm -rf "$TARGET_DIR"
      mv "$ROLLBACK" "$TARGET_DIR"
      fail "could not restore shared-data compatibility links; previous code restored"
    }
  done
fi
mkdir -p "$TARGET_DIR/config"
printf '%s\n' "$CHANNEL" >"$TARGET_DIR/config/update_channel"

ENTRY_DIR="${MCPE_ENTRY_DIR:-$PARENT}"
ENTRY_BACKUP="$WORK/entry.previous"
[ -f "$ENTRY_DIR/$TARGET_ENTRY" ] && cp -p "$ENTRY_DIR/$TARGET_ENTRY" "$ENTRY_BACKUP"
if ! cp -f "$WORK/extract/ports/$TARGET_ENTRY" "$ENTRY_DIR/$TARGET_ENTRY"; then
  rm -rf "$TARGET_DIR"
  [ -d "$ROLLBACK" ] && mv "$ROLLBACK" "$TARGET_DIR"
  [ -f "$ENTRY_BACKUP" ] && cp -p "$ENTRY_BACKUP" "$ENTRY_DIR/$TARGET_ENTRY"
  fail "entrypoint update failed; previous payload restored"
fi
chmod +x "$ENTRY_DIR/$TARGET_ENTRY" "$TARGET_DIR"/*.sh 2>/dev/null || true

show_msg "$TARGET_EDITION installed: $RELEASE_VERSION ($CHANNEL)." \
         "Rollback code is retained at $(basename "$ROLLBACK")." \
         "Shared APKs and worlds were not touched."
exit 0
