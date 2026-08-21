# Minecraft Bedrock for ARM Linux handhelds

![Minecraft Bedrock running on a handheld](screenshot.png)

Run a legally owned Android copy of Minecraft Bedrock natively on supported
ARM Linux handhelds through PortMaster and the open-source minecraft-linux
launcher. This is a testing release: supported combinations are documented,
but the final R36S and revised RGDS physical acceptance checks are still
pending. Nothing in rc.4 is promoted to stable or newly labelled Validated.

> **No game files are included.** You must supply your own official Minecraft
> Bedrock Android APK or complete split-APK set.
>
> **NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
> MOJANG OR MICROSOFT.**

## Download v2.0.0-rc.4

This version is a prerelease. Download an install archive from the release
assets, not GitHub's automatically generated **Source code** archives.

| Download | Who needs it |
|---|---|
| [Standard edition](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/minecraftbedrock-standard-v2.0.0-rc.4.zip) | Normal single-screen PortMaster devices; supports aarch64 and armhf |
| [RGDS edition](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/minecraftbedrock-rgds-v2.0.0-rc.4.zip) | Anbernic RG DS on ROCKNIX/Sway; arm64 only |
| [Windows APK helper](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/mcbedrock-get-windows-v2.0.0-rc.4.zip) | Downloads your own Google Play purchase in the correct arm64 format |
| [Project source bundle](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/minecraftbedrock-source-v2.0.0-rc.4.zip) | Maintainers and license compliance; not an install archive |
| [Standard SPDX SBOM](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/minecraftbedrock-standard-v2.0.0-rc.4.spdx.json) | Machine-readable contents of the standard archive |
| [RGDS SPDX SBOM](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/minecraftbedrock-rgds-v2.0.0-rc.4.spdx.json) | Machine-readable contents of the RGDS archive |
| [Release notes](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/RELEASE_NOTES.md) | Short packaged release summary |
| [Checksums](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/SHA256SUMS.txt) | Verifies every published file |

Use the **standard edition** unless you own an RG DS and specifically want the
dual-screen companion. The standard edition intentionally redirects RGDS users
to the separate RGDS package instead of silently installing experimental code.

## What you need

- A supported ARM Linux handheld with a working PortMaster installation.
- About 2 GB of free space for the port, runtime, and extracted game.
- Your own Minecraft Bedrock Android purchase. The Windows helper requires the
  Google account that owns Minecraft on Google Play; purchases from other
  storefronts are separate entitlements.
- A matching Android ABI:

| Device class | APK split |
|---|---|
| Most 64-bit handhelds, including H700 devices and RGDS | `arm64-v8a` |
| 32-bit R36S/RK3326-class firmware | `armeabi-v7a` |

If you are unsure, launch the installed port once. Its host probe and Support
bundle report the detected architecture without needing a Minecraft APK.

## Quick start

### 1. Put the port on the SD card

Extract exactly one port archive at the root of the storage that contains your
ROM folders:

| Firmware | Extract to |
|---|---|
| muOS | SD-card root, normally `/mnt/mmc` or `/mnt/sdcard` |
| Knulli | Share root or second SD-card root, the location containing `roms/` and `ports/` |
| ROCKNIX | Games-partition root, shown on-device as `/storage/roms` |
| R36S-class PortMaster setup | Storage root containing `roms/ports/` |

The archive supplies launch entries under both `roms/ports/` and `ports/` so
the supported firmware layouts find the same payload. Refresh the Ports list,
then launch **Minecraft Bedrock** once. This creates the shared data folders.

### 2. Download your owned Bedrock APKs on Windows

The easiest supported arm64 route is the Windows helper:

1. Open PowerShell as administrator, run `wsl --install -d Ubuntu`, and reboot
   if Windows asks.
2. Extract `mcbedrock-get-windows-v2.0.0-rc.4.zip` to a normal folder.
3. Run `mcbedrock-get.exe`, enter the Google email that owns Minecraft, and
   complete Google's sign-in page. The helper never asks for your password.
4. Accept the one-time WSL setup. An Ubuntu terminal opens and asks for your
   Ubuntu password while it builds the current minecraft-linux downloader.
5. Keep **64-bit arm64-v8a** selected for RG34XX SP/RGDS, or select **32-bit
   armeabi-v7a** for armhf R36S firmware, then press **Download 1.16.221.01**.
   Keep every APK created in the selected output folder together.

PyInstaller executables can trigger antivirus heuristics. Verify the bundle
against the published SHA-256 before allowing it. See
[the complete Windows guide](GETTING-BEDROCK-APKS.md) for architecture choice,
sign-out, and troubleshooting.

RG34XXSP users on Knulli Scarab can instead try **Get APK from Google Play**
inside the port. It is optional and controller-only: Google's page handles the
password and phone approval, an on-screen keyboard handles text entry, and the
port validates and installs the downloaded ARM64 split set automatically. No
browser runtime is downloaded and no account prompt appears unless that menu
item is selected. See [the APK guide](GETTING-BEDROCK-APKS.md#experimental-on-device-method-rg34xxsp--knulli-scarab)
for storage, controls, session removal, and prototype limitations.

### 3. Copy and install the complete set

Copy the full APK, one `.apkm`/`.apks`/`.xapk` bundle, or **every APK from one
split-set download** into:

```text
ports/minecraftbedrock-data/apk/
```

Launch the port, choose **Install APK**, select the detected set, and confirm.
Installation can take several minutes. The progress screen now stays visible;
do not power the device off while it is extracting.

The installer expands bundles into private temporary storage and validates
package identity, version, signing data, dependencies, and ABI before publishing
anything. A kernel lock prevents simultaneous installs. Its recovery journal
rolls back an interrupted multi-ABI commit on the next attempt; originals and
previous versions remain intact.

### 4. Play

Open **Versions**, select the installed build, then choose **Play**. The
launcher remembers the selection. After a successful install you may keep the
APKs for recovery or delete them from the launcher with **X**.

## Recommended Bedrock versions

| Version | ABI | Recommendation | Notes |
|---|---|---|---|
| **1.16.221.01** | arm64 / armhf | **Recommended** | Best handheld UI scaling and the smoothest tested everyday experience |
| **1.21.51.01** | arm64 | Newest tested no-RenderDragon build | Only the registered original native-library fingerprint receives this label; later reuploads may stutter badly |
| 1.17–1.21 RenderDragon-era builds | arm64 | Optional compatibility tests | Generally have tiny UI and severe stutter on the reference handhelds |
| 1.26+ | arm64 | **Unsupported** | Uses PairIP/new Android ABI behavior not supported by the legal upstream launcher path |

The launcher identifies installed versions from Android metadata and the game
library hash, not from filenames. Exact status and evidence are in
[the compatibility registry](portmaster/minecraftbedrock/COMPATIBILITY.md).

## Firmware compatibility status

| Firmware path | Client/backend | Current evidence |
|---|---|---|
| RG34XXSP / Knulli Scarab | arm64, Mali/Weston | Physical launch, controls, local play, audio, exit cleanup, and on-device downloader checkpoint tested |
| RG34XXSP / muOS | arm64, Mali/Weston with PipeWire routing | Game/audio path previously verified on muOS 2601; host, ABI, and frontend contracts are regression-tested |
| ROCKNIX / Sway | arm64, Wayland | RGDS path physically tested; standard single-screen devices use the same capability path but remain Best Effort per model |
| R36S/RK3326 dArkOS and related ArkOS builds | armhf, SDL3 KMSDRM/Wayland | Host, ABI, display, and cleanup fixtures pass; final physical R36S acceptance is still pending |
| Other PortMaster CFW/device combinations | capability-selected | Best Effort until a support bundle and physical launch add evidence for that exact combination |

Firmware names annotate known quirks, but capability probes choose graphics,
audio, display size, ABI, and compositor handoff. This prevents a renamed CFW
or derivative from being forced onto an unrelated device path.

## Launcher menu

- **Play** — start the selected version.
- **Versions** — select or remove installed game versions without deleting
  worlds.
- **Get APK from Google Play** — optional RG34XXSP/Knulli on-device download,
  sign-in, validation, and install.
- **Install APK** — install a validated full APK, APK bundle, or split set.
- **Settings** — configure FPS cap, render distance, client ABI, UI scale,
  VSync, performance tuning, and FPS logging.
- **Backup** — archive and restore profiles, worlds, and launcher settings.
- **Update port** — install the correct edition/channel update over the current
  code while preserving shared data.
- **Support bundle** — create a local redacted diagnostic archive.
- **Controller test** — record the detected pad and inputs locally.

Menu controls are D-pad to move, **A** to select, **B** to go back, **X** to
delete, and Left/Right to change settings. The launcher detects firmware
button-label differences; `MCPE_MENU_CONFIRM=a|b` remains available as an
advanced override.

For H700-class systems, start with a 30–40 FPS cap and 3–4 chunk render
distance. The 32-bit R36S path automatically starts more conservatively at
10 FPS, requests 2 chunks, and disables expensive visual effects; a Bedrock
version may enforce a higher internal render-distance minimum. Users can still
override FPS and distance in **Settings**, or disable the visual preset with
**Auto-tune options**. The port restores performance, display, frontend, and
input state after normal exit or a supervised failure.

## Updates and backups

Use **Backup** before testing a new game version, firmware, or port prerelease.
Backups contain launcher settings, profiles, and worlds, but never the supplied
APK or extracted version; keep the original complete APK set separately for
recovery. Use **Update port** to install updates for the current standard or
RGDS edition and selected channel. An update replaces port code only and keeps
the shared user-data directory intact.

## Standard and RGDS editions

Both editions share only user-owned data under:

```text
ports/minecraftbedrock-data/
  apk/       original installers
  versions/  validated extracted game versions
  profiles/  worlds and per-version player data
  backups/   local backup archives
```

Their code, logs, runtime, caches, update channel, and temporary state remain
separate. Updating one edition cannot overlay the other.

The RGDS edition adds a five-tab lower-screen companion with HUD, Chat, Items,
Input, and Settings pages, live status, a local-world terrain map, touch
routing, on-screen keyboard supervision, and SELECT screen swapping. Its
supported host is RGDS on ROCKNIX/Sway. Non-ROCKNIX RGDS systems are
experimental.

When you join a world hosted by another device, Bedrock does not store that
host's LevelDB world database locally. RGDS therefore keeps live status but
shows `REMOTE WORLD / MAP UNAVAILABLE` and clears old local terrain instead of
displaying a misleading cached map.

## Updating from 1.x

The first 2.x launch migrates APKs, installed versions, profiles, and backups
into the shared data directory. It inventories both locations first, refuses
ambiguous collisions, writes a recovery manifest, and keeps rollback state
until the first clean game exit.

Do not delete an old installation before this migration. If the launcher
reports that both old and new locations contain data, move one copy aside and
launch again; it will not choose one destructively.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Installer says the set is incomplete | Copy every APK from one download (or its untouched APKM/APKS/XAPK bundle), including the base and ABI split; do not mix versions |
| Game installs but does not start | Confirm `arm64-v8a` for most 64-bit systems or `armeabi-v7a` for armhf firmware |
| Installation appears frozen | Wait for the progress stage to complete; large asset extraction can take several minutes |
| Tiny UI or heavy stutter | Select 1.16.221.01 and start with 30–40 FPS and 3–4 chunks |
| R36S reports no matching video mode | Use rc.3 or newer; the launcher now selects an actual connected DRM mode instead of assuming 640×480 |
| Buttons are wrong | Run **Controller test**, then include its redacted output in a device report |
| Black screen or failed relaunch | Reboot once, then create a **Support bundle** before changing files manually |
| Windows helper cannot find WSL | Install Ubuntu with `wsl --install -d Ubuntu`; set `MCBEDROCK_WSL_DISTRO` only when using a differently named Ubuntu distro |
| Windows helper hangs at “Passing your Google session” | Replace rc.3 with rc.4 or newer; rc.3 could loop in upstream interactive authentication until its five-minute timeout |
| Windows helper says Minecraft is for sale | Sign out and use the Google account that owns the Google Play Android edition |

See [SUPPORT.md](SUPPORT.md) for report requirements. Never upload APKs,
extracted game libraries/assets, worlds, account data, private server details,
`versions/`, `profiles/`, or `libminecraftpe.so`.

## Maintainers and source

- [Testing evidence](TESTING.md)
- [Release checklist](RELEASE_CHECKLIST.md)
- [Source build and patch information](source_release/README.md)
- [Legal notes](LEGAL.md) and [third-party notices](THIRD_PARTY_NOTICES.md)
- [Credits](CREDITS.md) and [contribution guide](CONTRIBUTING.md)

`VERSION` is the release authority. Pinned containers build the standard
aarch64/armhf clients, RGDS client and companions, and the context bridge.
Release assembly creates deterministic edition archives, SPDX SBOMs, source
materials, checksums, and an edition-aware updater index. See the checklist
before promoting any prerelease to stable.

Port by DankMiimer.
