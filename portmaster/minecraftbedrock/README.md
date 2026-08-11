# Minecraft Bedrock handheld port

This archive installs an unofficial PortMaster launcher for a legally owned
Android copy of Minecraft Bedrock. It runs the native ARM game library through
the open-source minecraft-linux launcher.

This is a testing prerelease. Final R36S and revised RGDS physical acceptance
checks remain pending; rc.3 adds no stable or newly Validated claims.

**No game files are included.** Supply your own official full APK or complete
split-APK set.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Install this archive

Extract the archive at the root of the storage containing your ROM folders:

| Firmware | Extract to |
|---|---|
| muOS | SD-card root (`/mnt/mmc` or `/mnt/sdcard`) |
| Knulli | Share root or second SD-card root containing `roms/` and `ports/` |
| ROCKNIX | Games-partition root (`/storage/roms` on-device) |
| R36S-class setup | Storage root containing `roms/ports/` |

Refresh the Ports list and launch **Minecraft Bedrock** once. This creates:

```text
ports/minecraftbedrock-data/apk/
```

Copy your official APK files there, launch again, choose **Install APK**, and
select the complete detected set. Keep all files from one split download
together. Installation may take several minutes; wait for the progress screen
to finish.

The installer validates Android package metadata, signing data, dependencies,
and ABI before publishing the new version. A failed or mixed set does not
overwrite an existing install.

## Pick the correct APK

| Device class | Required APK split |
|---|---|
| Most 64-bit handhelds, H700 devices, and RGDS | `arm64-v8a` |
| 32-bit R36S/RK3326-class firmware | `armeabi-v7a` |

Bedrock **1.16.221.01** is recommended for its usable handheld UI scaling and
smooth performance. The fingerprinted original **1.21.51.01** is the newest
tested no-RenderDragon arm64 build, but its UI is smaller. Versions 1.26 and
newer are unsupported.

Windows arm64 users can download their own Google Play purchase with:

https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.3/mcbedrock-get-windows-v2.0.0-rc.3.zip

The helper requires Ubuntu under WSL and the Google account that owns the
Android edition. It downloads no game for an account without that entitlement.
For the full guide and armhf instructions, visit:

https://github.com/DankMiimer/minecraft-bedrock-handheld-port/blob/main/GETTING-BEDROCK-APKS.md

## Launcher menu

- **Play** starts the selected installed version.
- **Versions** selects or removes game versions without deleting worlds.
- **Install APK** installs one validated full APK or split set.
- **Settings** controls FPS, render distance, ABI, UI scale, VSync, and tuning.
- **Backup** saves and restores profiles, worlds, and launcher settings.
- **Update port** updates only this edition while preserving shared data.
- **Support bundle** creates a local redacted diagnostic archive.
- **Controller test** records local input detection for device reports.

Controls: D-pad navigates, **A** selects, **B** returns, **X** deletes, and
Left/Right changes settings.

## Editions and shared data

The standard archive supports normal single-screen aarch64 and armhf
PortMaster systems. RGDS users need the separate arm64 RGDS archive for the
dual-screen companion, touch routing, on-screen keyboard supervision, live
status, local-world map, and SELECT screen swapping. ROCKNIX/Sway is the
supported RGDS host.

Both editions share only user-owned data:

```text
ports/minecraftbedrock-data/
  apk/       original APKs
  versions/  extracted game versions
  profiles/  worlds and player data
  backups/   backup archives
```

Code, logs, runtime, cache, and update state remain separate. The first 2.x
launch safely migrates a 1.x layout and refuses ambiguous collisions instead
of overwriting either copy.

## Important limitations

- Compatibility is best effort unless the exact device/firmware combination
  is marked Validated.
- Xbox/Marketplace behavior is not a supported release gate; local worlds and
  LAN are the primary supported play paths.
- Newer RenderDragon-era versions can have severe stutter and very small UI.
- RGDS terrain mapping is available for local worlds only. Remote/LAN worlds
  retain live status but show `REMOTE WORLD / MAP UNAVAILABLE`.
- Never share APKs, extracted libraries/assets, worlds, profiles, account data,
  or `libminecraftpe.so` in public reports.

For troubleshooting, current compatibility status, source, and checksums:

https://github.com/DankMiimer/minecraft-bedrock-handheld-port
