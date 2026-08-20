#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GAMEDIR="$TMP/ports/minecraftbedrock"
mkdir -p "$GAMEDIR"/{apk,versions,profiles,config}
echo world >"$GAMEDIR/profiles/world.marker"
MCPE_EDITION_ID=minecraftbedrock.standard
MCPE_SHARED_DIRNAME=minecraftbedrock-data
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/common.sh"
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/migrate_data.sh"
mcpe_migrate_shared_data
[ -L "$GAMEDIR/profiles" ]
[ "$(cat "$TMP/ports/minecraftbedrock-data/profiles/world.marker")" = world ]
[ -f "$GAMEDIR/config/migration.pending" ]
mcpe_mark_migration_success
[ -f "$GAMEDIR/config/migration.completed" ]

# Legacy version directory names are converted once into metadata; runtime
# patch selection subsequently reads only version.json plus guarded symbols.
mkdir -p "$GAMEDIR/versions/1.16.221.01/lib/arm64-v8a"
printf game >"$GAMEDIR/versions/1.16.221.01/lib/arm64-v8a/libminecraftpe.so"
mkdir -p "$GAMEDIR/compat"
cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/compat/compatibility.json" "$GAMEDIR/compat/"
python3 "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/migrate_version_metadata.py" "$GAMEDIR"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version_name"])' \
  "$GAMEDIR/versions/1.16.221.01/version.json")" = 1.16.221.01 ]
grep -q 'http_resolver_guard' "$GAMEDIR/versions/1.16.221.01/version.json"
grep -q 'game_library_sha256' "$GAMEDIR/versions/1.16.221.01/version.json"
grep -q '"recommendation": "recommended"' "$GAMEDIR/versions/1.16.221.01/version.json"

# A fresh dedicated RGDS payload adopts the legacy standard data tree and
# leaves both editions linked to the shared root.
GAMEDIR="$TMP/rgds-ports/minecraftbedrock-rgds"
MCPE_SHARED_ROOT=""
MCPE_EDITION_ID=minecraftbedrock.rgds
mkdir -p "$GAMEDIR/config" "$TMP/rgds-ports/minecraftbedrock/profiles"
echo rgds-world >"$TMP/rgds-ports/minecraftbedrock/profiles/world.marker"
mcpe_migrate_shared_data
[ "$(cat "$TMP/rgds-ports/minecraftbedrock-data/profiles/world.marker")" = rgds-world ]
[ -L "$TMP/rgds-ports/minecraftbedrock/profiles" ]
[ -L "$GAMEDIR/profiles" ]

# A non-empty/non-empty collision must fail without changing either side.
GAMEDIR="$TMP/ports/collision"
mkdir -p "$GAMEDIR"/{apk,versions,profiles,config} "$TMP/ports/other-data"/{apk,versions,profiles,backups}
echo old >"$GAMEDIR/profiles/old"
echo new >"$TMP/ports/other-data/profiles/new"
MCPE_SHARED_ROOT="$TMP/ports/other-data"
if mcpe_migrate_shared_data; then echo "collision unexpectedly succeeded" >&2; exit 1; fi
[ -f "$GAMEDIR/profiles/old" ] && [ -f "$TMP/ports/other-data/profiles/new" ]

# Simulate power loss after an atomic move but before compatibility-link
# creation. The persistent "migrating" manifest must restore the old path.
GAMEDIR="$TMP/ports/crash"
MCPE_SHARED_ROOT="$TMP/ports/crash-data"
mkdir -p "$GAMEDIR/config" "$MCPE_SHARED_ROOT/profiles"
echo survived >"$MCPE_SHARED_ROOT/profiles/world"
printf 'schema=1\nstate=migrating\nmove=%s|%s\n' \
  "$GAMEDIR/profiles" "$MCPE_SHARED_ROOT/profiles" >"$GAMEDIR/config/migration.pending"
mcpe_recover_incomplete_migration "$GAMEDIR/config/migration.pending"
[ "$(cat "$GAMEDIR/profiles/world")" = survived ]
[ -f "$GAMEDIR/config/migration.recovered" ]

# Filesystems such as exFAT reject symlinks. The fallback records and creates
# a bind mount, and incomplete-migration recovery detaches its mountpoint.
FALLBACK_SRC="$TMP/fallback/source"
FALLBACK_DST="$TMP/fallback/shared"
FALLBACK_MANIFEST="$TMP/fallback/migration.pending"
mkdir -p "$(dirname "$FALLBACK_SRC")" "$FALLBACK_DST"
printf 'schema=1\nstate=migrating\n' >"$FALLBACK_MANIFEST"
MCPE_MIGRATION_ACTIONS=()
ln() { return 1; }
mount() { [ "$1" = --bind ] && [ "$2" = "$FALLBACK_DST" ] && [ "$3" = "$FALLBACK_SRC" ]; }
PRIVILEGED_LOG="$TMP/fallback/privileged.log"
sudo() { printf '%s\n' "$1" >>"$PRIVILEGED_LOG"; "$@"; }
ESUDO=sudo
mcpe_attach_shared_path "$FALLBACK_SRC" "$FALLBACK_DST" "$FALLBACK_MANIFEST" 1
[ -d "$FALLBACK_SRC" ]
grep -Fq "bind=$FALLBACK_SRC|$FALLBACK_DST" "$FALLBACK_MANIFEST"
grep -qx mount "$PRIVILEGED_LOG"
unset -f ln mount

mountpoint() { [ "$2" = "$FALLBACK_SRC" ]; }
umount() { [ "$1" = "$FALLBACK_SRC" ]; }
mcpe_recover_incomplete_migration "$FALLBACK_MANIFEST"
[ ! -e "$FALLBACK_SRC" ]
[ -f "$TMP/fallback/migration.recovered" ]
grep -qx umount "$PRIVILEGED_LOG"
ESUDO=""
unset -f mountpoint umount sudo

# Knulli keeps the shared tree hidden from its recursive Ports inventory. A
# pre-existing visible tree is merged without overwriting disjoint old data;
# byte-identical APK duplicates collapse and compatibility links are retargeted.
GAMEDIR="$TMP/knulli-ports/minecraftbedrock"
VISIBLE="$TMP/knulli-ports/minecraftbedrock-data"
HIDDEN="$TMP/knulli-ports/.minecraftbedrock-data"
mkdir -p "$GAMEDIR/config" "$VISIBLE/apk" "$VISIBLE/versions/new" \
  "$VISIBLE/profiles/new" "$VISIBLE/backups" "$HIDDEN/apk" \
  "$HIDDEN/versions/old" "$HIDDEN/profiles/old" "$HIDDEN/backups"
printf same >"$VISIBLE/apk/base.apk"
printf same >"$HIDDEN/apk/base.apk"
printf new >"$VISIBLE/versions/new/version.json"
printf old >"$HIDDEN/versions/old/version.json"
printf world-new >"$VISIBLE/profiles/new/world"
printf world-old >"$HIDDEN/profiles/old/world"
for item in apk versions profiles backups; do
  ln -s "$VISIBLE/$item" "$GAMEDIR/$item"
done
unset MCPE_SHARED_ROOT MCPE_SHARED_DIRNAME
CFW_NAME=knulli
MCPE_EDITION_ID=minecraftbedrock.standard
mcpe_migrate_shared_data
[ "$MCPE_SHARED_ROOT" = "$HIDDEN" ]
[ ! -e "$VISIBLE" ]
[ "$(cat "$HIDDEN/versions/new/version.json")" = new ]
[ "$(cat "$HIDDEN/versions/old/version.json")" = old ]
[ "$(cat "$HIDDEN/profiles/new/world")" = world-new ]
[ "$(cat "$HIDDEN/profiles/old/world")" = world-old ]
[ "$(readlink "$GAMEDIR/versions")" = "$HIDDEN/versions" ]
[ "$(find "$HIDDEN/apk" -name base.apk | wc -l)" -eq 1 ]
# A Knulli ES process started before relocation may keep exporting the old
# manifest default. A later port launch must recognize and replace that stale
# value instead of rejecting the already-retargeted compatibility links.
MCPE_SHARED_ROOT="$VISIBLE"
MCPE_SHARED_DIRNAME=minecraftbedrock-data
mcpe_migrate_shared_data
[ "$MCPE_SHARED_ROOT" = "$HIDDEN" ]
echo "migration tests passed"
