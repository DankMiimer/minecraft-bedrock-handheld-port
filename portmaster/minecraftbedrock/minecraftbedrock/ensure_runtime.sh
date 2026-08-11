#!/bin/bash
# Resolve a runtime module from PortMaster or a checksummed edition-local cache.
set -u
GAMEDIR="${GAMEDIR:?run via the port launcher}"
MODULE="${1:?runtime module id required}"
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh"
command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required for runtime validation" >&2; exit 1; }
SELECTED="$(python3 "$GAMEDIR/runtime_select.py" "$GAMEDIR/compat/runtime-index.json" "$MODULE")" || exit 1
eval "$SELECTED"

matches_hash() {
  [ -f "$1" ] || return 1
  [ "$(wc -c <"$1" | tr -d ' ')" = "$RUNTIME_SIZE" ] || return 1
  got="$(mcpe_sha256 "$1")" || return 1
  [ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" = "$RUNTIME_SHA256" ]
}

PM_DIR="${PM_DIR:-$(printf '\120\157\162\164\115\141\163\164\145\162')}"
for candidate in \
  "$GAMEDIR/runtime/$RUNTIME_FILENAME" \
  "${controlfolder:-/nonexistent}/libs/$RUNTIME_FILENAME" \
  "${controlfolder:-/nonexistent}/libs/weston_pkg_0.2.squashfs" \
  "/mnt/mmc/MUOS/$PM_DIR/libs/$RUNTIME_FILENAME" \
  "/mnt/sdcard/MUOS/$PM_DIR/libs/$RUNTIME_FILENAME"; do
  if matches_hash "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

mkdir -p "$GAMEDIR/runtime"
target="$GAMEDIR/runtime/$RUNTIME_FILENAME"
echo "Downloading verified runtime $MODULE ($((RUNTIME_SIZE / 1024 / 1024)) MiB)..." >&2
rm -f "$target.part"
mcpe_fetch "$RUNTIME_URL" "$target.part" || { rm -f "$target.part"; exit 1; }
matches_hash "$target.part" || { echo "runtime checksum/size mismatch" >&2; rm -f "$target.part"; exit 1; }
mv "$target.part" "$target"
printf '%s\n' "$target"
