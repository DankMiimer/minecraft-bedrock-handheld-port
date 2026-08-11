# Minecraft Bedrock handheld port

An unofficial PortMaster launcher for legally acquired Android Bedrock builds.
It runs the native ARM game library through the open-source minecraft-linux
launcher. No Mojang APK, game asset, account credential, or license bypass is
included. No game files are included.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Choose the correct edition

- `minecraftbedrock-standard-vX.Y.Z.zip` is the lightweight single-screen
  edition for aarch64 and armhf PortMaster systems. It contains no telemetry,
  minimap, dual-touch runtime, OSK supervisor, or RGDS experimental tooling.
- `minecraftbedrock-rgds-vX.Y.Z.zip` is the arm64 dual-screen edition. Its
  supported host is RGDS on ROCKNIX/Sway. It adds live map/status, FMOD
  telemetry, SELECT screen swapping, dual-touch routing, and OSK supervision.

The standard edition does not launch on RGDS. It offers a confirmed installer
for the RGDS edition when the release index and network are available, and
otherwise displays manual download instructions.

## Install

1. Extract exactly one edition archive into the device's PortMaster/ports
   layout.
2. Launch it once. Existing 1.x data is migrated transactionally.
3. Copy an official full APK or one complete official split set to
   `$PORTS/minecraftbedrock-data/apk/`.
4. Open **Install APK**, select the complete set, and install it.

For step 3 on Windows, see
[GETTING-BEDROCK-APKS.md](GETTING-BEDROCK-APKS.md). Google now refuses Play
downloads to third-party desktop clients, so the working route is the
minecraft-linux launcher under WSL. The guide covers installing it, selecting
`arm64-v8a` rather than the default `x86`, and copying a complete split set
across. No game content is distributed by this project.

The installer reads Android binary manifest metadata and signing data. It
groups files by package, version code/name, signer, dependencies, and ABI;
files from different groups are never mixed. Extraction happens in staging and
is atomically published only after validation. Original APKs and prior installs
remain intact on failure.

## Data and updates

The editions share only user-owned game data:

```text
$PORTS/minecraftbedrock-data/
  apk/       user-supplied installers
  versions/  validated extracted game versions
  profiles/  worlds, options, and 1.16-isolated profiles
  backups/   local backups
```

Each edition separately owns `config/`, `logs/`, `runtime/`, caches, temporary
state, and its `stable` or opt-in `testing` channel. Code updates download an
exact edition asset, validate its declared size/SHA-256 and archive paths, then
swap the whole payload atomically. They never overlay another edition or
modify shared data.

The first 2.x launch inventories the old layout, rejects ambiguous collisions,
writes a recovery manifest, prefers same-filesystem atomic moves, and leaves
compatibility links. Rollback state is retained until the first clean game
exit.

## Host compatibility

Hardware admission is capability-based, not a promise that every ARM device
was physically tested. The resolver records ABI, SoC/device tree, RAM,
compositor, connected DRM modes, graphics stack, audio services, input axes,
touch/output associations, permissions, and active resolution. It selects a
Wayland/Sway, Mesa KMSDRM, H700 proprietary-Mali/Weston, or X11 adapter.

Priority is: explicit user override, validated device profile, then automatic
capability selection. A connected DRM mode must exist before KMSDRM starts;
otherwise the launcher selects a safe compositor fallback or exits with an
actionable diagnostic. This is the R36S mode-selection fix—no fixed 640×480
mode is assumed.

Compatibility labels and the exact Bedrock registry are in
[`portmaster/minecraftbedrock/COMPATIBILITY.md`](portmaster/minecraftbedrock/COMPATIBILITY.md):

- **Validated** — passed the physical reference matrix.
- **Best effort** — admitted through a tested capability/backend path but not
  validated on that exact combination.
- **Unsupported** — a known ABI, PairIP, graphics, or runtime incompatibility.

## Bedrock versions

The compatibility registry, not a directory name, controls patches and
defaults. **1.16.221.01 is the recommended/default Bedrock version** because
its legacy UI scaling remains usable on handheld screens. The fingerprinted
original 1.21.51.01 is the newest tested no-RenderDragon arm64 build, but it is
not selected by default because of its poorer UI scaling. Later 1.21.51.01
reuploads are not assumed equivalent: only a registered `libminecraftpe.so`
SHA-256 receives the no-RenderDragon label; unknown variants show a warning.

The 1.16 EduMode and 1.16/1.17 HTTP resolver guards remain. The
1.20.62 compaction change is opt-in. Every patch first verifies its expected
symbol/signature; a mismatch logs and disables that patch instead of modifying
unknown code.

PairIP/new-ABI 1.26 packages are rejected before extraction because they need
legal upstream launcher support. This project does not attempt DRM or license
bypasses.

## RGDS controls and cleanup

The RGDS edition discovers outputs and touch devices from Sway/libinput
metadata rather than fixed `DSI-*`, Goodix, or `/dev/input/event*` names. The
game starts on the physical top panel and the companion UI on the bottom;
SELECT atomically swaps the two surfaces. Touch mappings follow the surfaces.

The lower-screen companion uses a Minecraft-style five-tab shell inspired by
the AYN Thor second-screen projects: **HUD**, **Chat**, **Items**, **Input**,
and **Settings**. A persistent status stack shows live position/FPS/dimension
and LevelDB snapshot health/hunger. HUD contains the centered terrain map;
Chat and Items are independent lower-screen views, so gameplay stays visible
on the other panel. Items provides a 36-slot grid and craftable-recipe pane;
Chat provides history and a touch keyboard. Their state/command ABI is bounded
and versioned, and unsupported actions stay visibly read-only rather than
modifying inventory memory. The exact `1.21.51.01` bridge is gated by the
installed game-library hash plus runtime RTTI/vtable/prologue checks.

The companion indexes and loads UI/item PNGs directly from the selected,
user-supplied Minecraft installation. No Mojang texture is included in a port
or source archive. Input supplies a 3×3 shortcut grid; Settings controls
status, automatic Items selection, night tint, and map following.

Terrain tiles come from the active local world's LevelDB. When RGDS joins a
world hosted by another device over LAN, Bedrock does not store that remote
database on the client. The companion therefore clears any previous local map,
pauses local terrain rendering, and shows `REMOTE WORLD / MAP UNAVAILABLE`
while retaining live position and status telemetry. It never presents cached
terrain from another world as the current LAN map.

For local worlds, the terrain worker follows the LevelDB directory actually
opened by the running game, so switching worlds does not wait for player
movement to change a log timestamp. Its default 12-chunk scan covers the
visible map at the normal zoom with one quarter of the old lookup count; the
central area is published before any optional wider cache ring.

Every child process and saved state is supervised. Cleanup is idempotent and
restores output placement, touch mapping, frontend state, OSK state, mounts,
temporary shared memory, and tuning after normal exit, signals, or a forced
game termination. Missing dual-output prerequisites produce diagnostics and a
clean exit. Non-ROCKNIX RGDS hosts are experimental.

## Diagnostics

Use **Support bundle** in the launcher. It creates a local, redacted archive
containing the resolved profile, runtime hashes, display modes, audio/input
detection, APK metadata, and relevant logs. Nothing is uploaded automatically.
Do not publish APKs, extracted game libraries, worlds, or account data.

Controller mappings prefer PortMaster's mapping. Unknown pads get a
conservative fallback based on evdev axis capabilities. Use the local
controller diagnostic when an unusual pad layout is not recognized.

## Reproducible releases

`VERSION` is the version authority. Pinned container builds create the standard
aarch64/armhf clients and the RGDS telemetry/independent-companion client from
the same commits.
`scripts/build_releases.py` replaces all payload clients with those artifacts,
adds the versioned Crusty context API module, creates deterministic archives,
SPDX SBOMs, source/license bundles, SHA-256 sums, release notes, and the
edition-aware release index. Packaging fails on private/Mojang inputs or any
dual-screen marker in the standard archive.

See [TESTING.md](TESTING.md) for current evidence and
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for blocking promotion gates.
