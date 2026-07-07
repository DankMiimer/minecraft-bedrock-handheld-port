# Minecraft Bedrock Edition — manual install port

Minecraft Bedrock Edition running **natively** (no emulation, no streaming)
on aarch64 Linux handhelds, via the
[minecraft-linux mcpelauncher](https://github.com/minecraft-linux/mcpelauncher-manifest)
with a custom EGLUT game-window backend on a Weston/crusty
graphics stack.

**Tested on:**
- Anbernic RG34XX-SP (Allwinner H700, 720x480) running Knulli
- Anbernic RG DS (Rockchip RK3566, dual 640x480) running ROCKNIX — the game
  runs on the primary screen; both touchscreens are mapped to it during play

It should also work on other H700-family devices (RG35XX-H/Plus/SP 2024,
RG40XX, etc.) running Knulli or muOS, and other Mali-blob ROCKNIX devices —
reports welcome. It will NOT work on 32-bit-only devices.

**No game files are included.** You must provide your own legally obtained
Minecraft Bedrock Edition APK (arm64-v8a).

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Download

- Latest release: [v1.3.1](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/tag/v1.3.1)
- Port zip: [minecraftbedrock-1.3.1.zip](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v1.3.1/minecraftbedrock-1.3.1.zip)
- SHA-256: compare against the checksum shown on the GitHub release page or
  in `SHA256SUMS.txt`.

Do not download this repository as the install package. Use the release zip
above; GitHub's "Source code" archives are only for the repository contents.

## Quick Start

1. Extract this zip into your handheld's ports folder. On muOS, put the `.sh`
   files in `/roms/Ports/` and the `minecraftbedrock/` folder in `/ports/`.
2. Copy your own legally obtained Minecraft Bedrock arm64 APK file(s) into
   `minecraftbedrock/apk/`.
3. Launch **Minecraft Bedrock** once to extract the game.
4. Delete the APK file(s) from `minecraftbedrock/apk/`.

## Requirements

- aarch64 device on Knulli, muOS, or ROCKNIX-style PortMaster setup
- ~2 GB free space on the ports partition (game assets are large)
- WiFi on first launch so the launcher can fetch its Weston runtime if it is
  missing (53 MB), or a preinstalled compatible `weston_pkg_0.2` runtime
- A Minecraft Bedrock **arm64** APK. Tested: **1.16.221.01** and **1.20.x**
  (1.20.15 / 1.20.51 / 1.20.62). 1.21+ may work; 1.26+ Play builds do **not**
  (PairIP licensing). 32-bit (armeabi-v7a) APKs do not work.
- **Tip — UI size:** on 1.17 and newer the in-game GUI Scale is locked small
  at these resolutions (an engine limitation, no fix launcher-side).
  **1.16.221.01 has a working GUI Scale slider** (Settings → Video), so it
  gives a properly sized UI at native resolution. On tested devices,
  1.16.221.01 runs perfectly without stutters. If the small UI on modern
  versions bothers you, 1.16 is the recommended version.

## Version Notes

| Version | Status | Notes |
|---|---|---|
| 1.16.221.01 arm64 | Recommended for small screens | Working GUI Scale slider; runs perfectly without stutters on tested devices; uses its own world/profile entry. |
| 1.20.15 / 1.20.51 / 1.20.62 arm64 | Tested | Modern gameplay; UI scale is smaller on these handheld screens. |
| 1.21+ arm64 | Untested / may work | Not a primary target yet. |
| 1.26+ Play builds | Unsupported | Newer Android licensing/runtime dependencies are not supported by this port. |
| 32-bit / armeabi-v7a builds | Unsupported | This port requires aarch64 and `arm64-v8a` game libraries. |

## Install

1. Extract this zip into your ports directory.
   - Knulli: put `Minecraft Bedrock.sh`, `Minecraft Bedrock 1.16.sh`, and the
     `minecraftbedrock/` folder directly in `/userdata/roms/ports/`.
   - muOS: put the `.sh` files in `/roms/Ports/` and put the
     `minecraftbedrock/` folder in `/ports/`.
2. Copy your APK into `minecraftbedrock/apk/`. A single full APK or Google
   Play split APKs (base + arm64 + install-pack, together) both work.
3. Update your game list and launch **Minecraft Bedrock** from Ports. The
   first run extracts the game — give it a few minutes.
4. Delete the APK from the `apk/` folder afterwards.

Expected layout after extraction:

```text
ports/
  Minecraft Bedrock.sh
  Minecraft Bedrock 1.16.sh
  minecraftbedrock/
    apk/
      PUT_APK_HERE.txt
    bin/
    controls/
    libs.aarch64/
    setup_apk.sh
    run_bedrock.sh
```

For Google Play split APKs, copy the relevant files together into
`minecraftbedrock/apk/`, for example:

```text
base.apk
split_config.arm64_v8a.apk
split_install_pack.apk
```

You can install several versions (drop each APK in `apk/` and launch once).
The main **Minecraft Bedrock** entry runs the newest installed version.

### 1.16.221.01

For the working GUI Scale slider, install 1.16.221.01 and use the separate
**Minecraft Bedrock 1.16** entry — it runs 1.16 with its own isolated world
(older clients cannot open newer worlds). On first launch, dismiss the Xbox
sign-in prompt (press **B**) to reach the menu; sign-in is not supported.
On tested devices, 1.16.221.01 runs perfectly without stutters.

Notes: 1.16 has no cross-version LAN with 1.20, and this port applies small
built-in compatibility patches so 1.16.221.01 boots (Education Mode off,
online services disabled — LAN still works).

**LAN multiplayer flow** (same as any Bedrock version): one player opens a
world and stays in it (the host); the other player, from the **main menu**,
goes to **Play → Friends tab** and the host's world appears under "LAN
Games". You can't see each other if you're both sitting in your own separate
worlds — one hosts, the other joins from the menu. Verified working on 1.16
between an RG34XX-SP and an RG DS.

## Notes and limitations

- **No Xbox Live / Marketplace sign-in.** Local worlds work. **LAN
  multiplayer works** — verified between an RG34XX-SP (Knulli) and an RG DS
  (ROCKNIX) in the same world.
- **Audio** uses the launcher's OpenAL backend, which outputs through
  PulseAudio on Knulli and ROCKNIX (pipewire-pulse). On ALSA-only systems with
  no Pulse/PipeWire server (e.g. **muOS**), the port detects the missing server
  and automatically routes OpenAL to ALSA, so sound works out of the box.
  Force a specific OpenAL output with `MCPE_ALSOFT_DRIVERS` (e.g. `alsa` or
  `pulse`). Optional: drop a host (glibc aarch64) FMOD Engine `libfmod.so.12.0`
  from fmod.com into `minecraftbedrock/fmod/` to use real FMOD instead.
- **No virtual keyboard.** Set world names etc. from a PC; save data lives in
  `minecraftbedrock/profiles/default/mcpelauncher/games/com.mojang/`.
- While the game runs, the CPU governor is set to `performance` and the GPU
  minimum clock is raised; both are restored on exit
  (disable with `MCPE_PERFORMANCE_MODE=0`).
- On 4-core devices a measured thread-affinity layout is applied (render and
  simulation threads get dedicated cores) — this roughly quartered stutter on
  the H700. Recommended in-game settings for H700: render distance 3-4
  chunks, 30-40 FPS cap.
- EmulationStation is fully stopped during play and restarted afterwards
  on Knulli. On muOS, the frontend/mux launcher is stopped while Weston owns
  the framebuffer and restarted on exit.

## Controls

Default Bedrock gamepad layout (left stick move, right stick camera,
R1/RT break, L1/LT place, A jump, Start pause). Controller mappings are
matched by controller GUID from `minecraftbedrock/controls/` — hand-tuned:
RG34XX-SP (whose line also covers other Anbernic H700-family pads, they
share the same GUID), RG DS. **Unknown controllers get an auto-generated
standard-layout mapping** at launch (logged in `log.txt`) — if buttons feel
wrong on your device, see `controls/README.md` to tune the line, and please
share it!

On dual-screen devices the touchscreen(s) are remapped to the game's display
while the port runs (sway `map_to_output`, the same approach ROCKNIX uses
for DraStic). If ES touch behaves oddly after quitting, restart ES or reboot.

## Troubleshooting

Logs live at `minecraftbedrock/log.txt` and
`minecraftbedrock/weston_launch.log`.

| Symptom | Likely cause | Fix |
|---|---|---|
| No Minecraft version installed | No APK was copied, or extraction failed before creating `versions/` | Copy your legally obtained arm64 APK(s) into `minecraftbedrock/apk/` and launch again. |
| 32-bit APK error | The APK only contains `armeabi-v7a` libraries | Use an `arm64-v8a` APK. |
| `Unable to locate asset: bootstrap.json` | APK assets were flattened or split files are incomplete | Re-run setup with the original APK/split files together; do not rearrange `assets/assets/`. |
| Black screen after crash | Display/session cleanup did not finish | On Knulli, restart EmulationStation with `/etc/init.d/S31emulationstation start`; on muOS, relaunch the frontend or reboot. |
| Buttons are wrong | Controller GUID is not mapped yet | Open an issue with device, firmware, and the generated mapping/log lines. |
| Tiny UI in newer versions | 1.17+ locks GUI scale on these screens | Use 1.16.221.01 for the best UI. |

## Verify the Download

Windows PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 .\minecraftbedrock-1.3.1.zip
```

Linux/macOS:

```sh
sha256sum minecraftbedrock-1.3.1.zip
```

Compare the result with the SHA-256 value published on the GitHub release
page. The README inside the zip does not hardcode the final zip hash because
that would change the archive being verified.

## Reporting Issues

Please use the issue templates. Include your device, firmware, Minecraft APK
version, and the relevant log text.

Do **not** upload APKs, extracted `versions/`, `profiles/`, worlds, or any
Mojang/Microsoft game files. Reports that require those files cannot be
handled publicly.

## Source

The launcher is GPL-3.0. The complete modified source is provided as patch
files in `source_release/` (see its README for base commits and build
instructions) and as branch `rg34xxsp-port` on the forks under
https://github.com/DankMiimer (mcpelauncher-manifest, mcpelauncher-client,
game-window, libc-shim, linux-gamepad — recursive-clone the manifest fork to
build). Licenses for all shipped components are included inside the release
zip under `minecraftbedrock/licenses/`; repository-level notes live in
[`LEGAL.md`](LEGAL.md) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

For device testing notes, see [`TESTING.md`](TESTING.md). Support and
contribution guidance lives in [`SUPPORT.md`](SUPPORT.md) and
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Credits

See [`CREDITS.md`](CREDITS.md) for detailed credits and third-party notices.

Port by DankMiimer.
