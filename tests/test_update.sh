#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PORTS="$TMP/ports"
CURRENT="$PORTS/minecraftbedrock"
ENTRY="$PORTS"
mkdir -p "$CURRENT/lib" "$CURRENT/config" "$CURRENT/logs" "$CURRENT/runtime" "$CURRENT/profiles"
cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/update_port.sh" "$CURRENT/"
cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/release_select.py" "$CURRENT/"
cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/common.sh" "$CURRENT/lib/"
cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/migrate_data.sh" "$CURRENT/lib/"
cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/edition.json" "$CURRENT/edition.json"
printf '1.6.1\n' >"$CURRENT/PORT_VERSION"
printf 'testing\n' >"$CURRENT/config/update_channel"
printf 'keep-config\n' >"$CURRENT/config/user.cfg"
printf 'keep-world\n' >"$CURRENT/profiles/world"
printf 'old-entry\n' >"$ENTRY/Minecraft Bedrock.sh"

make_asset() {
  local version="$1" edition="$2" destination="$3"
  local stage="$TMP/stage-$version"
  mkdir -p "$stage/ports/minecraftbedrock/lib"
  cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/release_select.py" "$stage/ports/minecraftbedrock/"
  cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/update_port.sh" "$stage/ports/minecraftbedrock/"
  cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/common.sh" "$stage/ports/minecraftbedrock/lib/"
  cp "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/migrate_data.sh" "$stage/ports/minecraftbedrock/lib/"
  printf '{\n  "id": "%s",\n  "schema": 1,\n  "name": "test",\n  "payload": "minecraftbedrock",\n  "entrypoint": "Minecraft Bedrock.sh",\n  "channel": "testing",\n  "shared_data": "minecraftbedrock-data",\n  "host_abis": ["aarch64"],\n  "updater_schema": 2\n}\n' \
    "$edition" >"$stage/ports/minecraftbedrock/edition.json"
  printf '%s\n' "$version" >"$stage/ports/minecraftbedrock/PORT_VERSION"
  printf 'new-%s\n' "$version" >"$stage/ports/minecraftbedrock/new.marker"
  printf '#!/bin/bash\n' >"$stage/ports/Minecraft Bedrock.sh"
  (cd "$stage" && zip -qr "$destination" .)
}

ASSET="$TMP/update.zip"
make_asset 2.0.0 minecraftbedrock.standard "$ASSET"
SIZE="$(wc -c <"$ASSET" | tr -d ' ')"
HASH="$(sha256sum "$ASSET" | awk '{print $1}')"
INDEX="$TMP/index.json"
printf '{"schema":2,"releases":[{"edition":"minecraftbedrock.standard","channel":"testing","version":"2.0.0","asset":"update.zip","url":"file://%s","sha256":"%s","size":%s,"minimum_updater":2}]}\n' \
  "$ASSET" "$HASH" "$SIZE" >"$INDEX"
MCPE_RELEASE_INDEX_URL="file://$INDEX" MCPE_GAMEDIR="$CURRENT" MCPE_ENTRY_DIR="$ENTRY" \
  bash "$CURRENT/update_port.sh"
[ "$(cat "$CURRENT/new.marker")" = new-2.0.0 ]
[ "$(cat "$CURRENT/config/user.cfg")" = keep-config ]
[ "$(cat "$PORTS/minecraftbedrock-data/profiles/world")" = keep-world ]
[ -L "$CURRENT/profiles" ]
[ -d "$PORTS/.minecraftbedrock.rollback" ]
[ -L "$PORTS/.minecraftbedrock.rollback/profiles" ]

# A wrong-edition archive must be rejected before any swap.
WRONG="$TMP/wrong.zip"
make_asset 3.0.0 minecraftbedrock.rgds "$WRONG"
WSIZE="$(wc -c <"$WRONG" | tr -d ' ')"; WHASH="$(sha256sum "$WRONG" | awk '{print $1}')"
printf '{"schema":2,"releases":[{"edition":"minecraftbedrock.standard","channel":"testing","version":"3.0.0","asset":"wrong.zip","url":"file://%s","sha256":"%s","size":%s,"minimum_updater":2}]}\n' \
  "$WRONG" "$WHASH" "$WSIZE" >"$INDEX"
if MCPE_RELEASE_INDEX_URL="file://$INDEX" MCPE_GAMEDIR="$CURRENT" MCPE_ENTRY_DIR="$ENTRY" \
   bash "$CURRENT/update_port.sh"; then
  echo "wrong-edition update unexpectedly succeeded" >&2; exit 1
fi
[ "$(cat "$CURRENT/new.marker")" = new-2.0.0 ]
echo "updater tests passed"
