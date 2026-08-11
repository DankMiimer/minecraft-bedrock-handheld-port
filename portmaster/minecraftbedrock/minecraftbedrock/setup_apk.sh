#!/bin/bash
# Metadata-driven, transactional installer for user-supplied Bedrock APKs.
set -u
GAMEDIR="${GAMEDIR:?run via 'Minecraft Bedrock.sh'}"
APKDIR="$GAMEDIR/apk"
ERROR_FILE="$GAMEDIR/setup_error.txt"
rm -f "$ERROR_FILE" 2>/dev/null

fail() {
  printf '[setup] ERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" >"$ERROR_FILE" 2>/dev/null
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail \
  "Python 3 is required for safe APK manifest/split validation on this firmware."
[ -f "$GAMEDIR/apkmeta.py" ] || fail "APK metadata helper is missing; reinstall the port."

if [ "$#" -gt 0 ]; then
  APKS=("$@")
else
  shopt -s nullglob
  APKS=("$APKDIR"/*.apk)
  shopt -u nullglob
fi
[ "${#APKS[@]}" -gt 0 ] || fail "no APK files found in $APKDIR"

for apk in "${APKS[@]}"; do
  [ -f "$apk" ] || fail "APK not found: $apk"
done

echo "[setup] Inspecting manifests, splits, ABIs, and signing identity..."
OUTPUT="$(python3 "$GAMEDIR/apkmeta.py" --install --gamedir "$GAMEDIR" "${APKS[@]}" 2>&1)"
status=$?
printf '%s\n' "$OUTPUT"
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$OUTPUT" | sed -n 's/^ERROR: //p' >"$ERROR_FILE"
  [ -s "$ERROR_FILE" ] || printf '%s\n' "$OUTPUT" >"$ERROR_FILE"
  exit "$status"
fi

echo "[setup] Installation committed atomically. Original APK files were retained."
echo "[setup] Delete the APKs yourself after confirming the game launches."
