# bedrockmap — world-DB → minimap tile cache (IMPLEMENTED, PC-verified)

Status 2026-08-05: implemented (`bedrockmap.cpp` + `nbt.hpp` +
`png_write.hpp` + `block_colors.tsv`) and verified against the real
world copy in `dist/worlddbg/rgds/UO5JapW+AAA=` — rendered 217 chunks
around the player into 4 tiles; output visually confirmed as correct
terrain (rivers/forests/beaches, water depth tint, height shading), and
`player.json` extraction verified (pos/yaw/dim/health/hunger/day_time).
End-to-end with bottomd tile blitting also verified. Data3D and v9 signed
section indices were physically validated with Bedrock 1.21.51.01; the
renderer cache is schema-keyed so decoder changes invalidate stale tiles.
A LAN client does not expose the host world's LevelDB; the release supervisor
therefore pauses this worker for remote sessions instead of rendering a stale
local-world cache.
Local passes use a 12-chunk default radius. Chunks are visited center-first and
the central 10-chunk area is flushed before an optional outer ring, reducing
first-visible latency while preserving configurable wider caching.
A radius-12 pass =
56 ms on WSL x86 including PNG writes (device budget: measure on the
RG34XX-SP when integrating).

Build on WSL: `bash build_wsl.sh` (leveldb-mcpe clone/patch/build steps
documented inside; note the `zlibstatic`→`ZLIB::ZLIB` CMake fix and the
`-DDLLX=` define consumers need).

Remaining TODO:
- Golden-diff vs uNmINeD (orientation/transpose sanity looked right by
  eye, but confirm; index conventions are centralized and commented in
  bedrockmap.cpp).
- `--cave` mode untested.
- Sanitize INT_MIN spawn values in player.json (unset spawn).
- Static aarch64/armhf builds inside mcpe-build:bookworm.

Spec section: `RGDS_DUALSCREEN_PLAN.md` "Component 2". Data-source
assignments: `../analysis/SYMBOL_FINDINGS.md`.

## Contract (what bottomd expects)

CLI (single pass, exits when done; bottomd invokes it repeatedly):

```
bedrockmap --db <snapshot_dir>/db --out /dev/shm/mcpe_tiles/<worldid> \
           --center <x> <z> --radius-chunks 12 --dim 0 [--cave <y>]
```

Outputs:
- `<out>/<dim>/surface/r.<tx>.<tz>.png` — one tile = 16x16 chunks =
  256x256 px (1 px/block, chunk = 16 px). Atomic write (tmp + rename).
  Tile coords: `tx = floor(chunkX/16)`, `tz = floor(chunkZ/16)`.
- `<out>/player.json` — from the `~local_player` value (NBT) and
  `level.dat`: `{"dimension":0,"health":20,"hunger":20,"spawn":[x,y,z],
  "day_time":..., "pos":[x,y,z]}`. This is the ONLY source for
  dimension/health/hunger/day-time (see SYMBOL_FINDINGS — the live
  telemetry hook deliberately does not provide them).

`bottomd` consumes both outputs: raw terrain tiles feed the centered HUD map,
while `player.json` supplies snapshot health, hunger, dimension, world time,
and spawn data for its persistent status layer.

## Implementation notes (start here next session)

1. **Snapshot first, always.** Caller (bottomd's terrain thread, or a
   wrapper script during dev) copies the world `db/` dir to
   `/dev/shm/mcpe_dbsnap/` before invoking; never open the live DB.
   Trigger: every ~20 s + `db/CURRENT`/newest-`.log` mtime change,
   debounced.
2. **LevelDB fork:** Bedrock DBs need compressor IDs 2 (zlib) and 4
   (raw zlib): use `github.com/Amulet-Team/leveldb-mcpe` (or Mojang's
   `leveldb-mcpe`) — vanilla leveldb CANNOT open these. Bytewise default
   comparator. Build static inside the existing `mcpe-build:bookworm`
   Docker image (aarch64 + armhf; PC-native for tests).
3. **Keys** (little-endian): `int32 x, int32 z, [int32 dim if != 0],
   uint8 tag [, uint8 subchunkY]`. Tags: `0x2f` SubChunkPrefix, `0x2d`
   Data2D (heightmap+biomes, pre-1.18 — the 1.16 targets), `0x2b`
   Data3D (1.18+), `0x2c`/`0x76` chunk version, `~local_player` and
   `level.dat` (separate file, plain NBT after 8-byte header) for
   player.json.
4. **Subchunk (paletted, 1.13+):** version byte (8/9), storage count,
   per storage: bits-per-block byte (`(bpb<<1)|serialized_type`), packed
   u32 words (blocks per word = 32/bpb, no spanning), then palette:
   int32 count + that many NBT compounds (little-endian, uncompressed)
   with `name` (e.g. `minecraft:stone`). Column pixel = block at
   heightmap Y from Data2D; heightmap = first 256 uint16 LE of Data2D.
5. **Colors:** `block_colors.tsv` (name → RGB) shipped beside the
   binary; derive from community map-color tables (write our own file —
   do NOT copy a GPL-incompatible table verbatim without checking its
   license). Unknown block → stable hash-color, never black. Vanilla-map
   height shading: brighten/darken by neighbor-column Y delta; water
   depth tint.
6. **Testing without a device:** copy a real world from the RG34XX-SP
   (`profiles/<ver>/.../minecraftWorlds/<id>/db`) to the PC; golden-test
   against a uNmINeD render of the same world. Worlds are gitignored
   (`**/com.mojang/`, `**/level.dat`) — keep it that way.
7. **Perf target:** incremental pass (radius 12) <150 ms on one A53
   (RG34XX-SP) at nice +10 → guarantees RK3568 headroom.

## Why not in this session

Telemetry + bottomd skeleton landed first (verified, unblock everything
else); this component is self-contained PC work with zero unknowns
beyond elbow grease, so it was the safest thing to leave next.
