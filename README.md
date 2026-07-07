# Minecraft Bedrock Edition — manual install port

Minecraft Bedrock Edition running **natively** (no emulation, no streaming)
on aarch64 Linux handhelds, via the
[minecraft-linux mcpelauncher](https://github.com/minecraft-linux/mcpelauncher-manifest)
with a custom EGLUT game-window backend on PortMaster's Weston/crusty
graphics stack.

**Tested on:**
- Anbernic RG34XX-SP (Allwinner H700, 720x480) running Knulli
- Anbernic RG DS (Rockchip RK3566, dual 640x480) running ROCKNIX — the game
  runs on the primary screen; both touchscreens are mapped to it during play

It should also work on other H700-family Knulli devices (RG35XX-H/Plus/SP
2024 models) and other Mali-blob ROCKNIX devices — reports welcome. It will
NOT work on 32-bit-only devices.

**No game files are included.** You must provide your own legally obtained
Minecraft Bedrock Edition APK (arm64-v8a).

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Requirements

- aarch64 device on a Batocera-family CFW (Knulli tested)
- ~2 GB free space on the ports partition (game assets are large)
- WiFi on first launch **or** PortMaster installed (the port needs
  PortMaster's `weston_pkg_0.2` runtime and downloads it automatically if
  missing, 53 MB)
- A Minecraft Bedrock **arm64** APK. Tested: **1.16.221.01** and **1.20.x**
  (1.20.15 / 1.20.51 / 1.20.62). 1.21+ may work; 1.26+ Play builds do **not**
  (PairIP licensing). 32-bit (armeabi-v7a) APKs do not work.
- **Tip — UI size:** on 1.17 and newer the in-game GUI Scale is locked small
  at these resolutions (an engine limitation, no fix launcher-side).
  **1.16.221.01 has a working GUI Scale slider** (Settings → Video), so it
  gives a properly sized UI at native resolution. If the small UI on modern
  versions bothers you, 1.16 is the recommended version.

## Install

1. Copy `Minecraft Bedrock.sh` and the `minecraftbedrock/` folder into your
   ports directory (Knulli: `/userdata/roms/ports/`).
2. Copy your APK into `minecraftbedrock/apk/`. A single full APK or Google
   Play split APKs (base + arm64 + install-pack, together) both work.
3. Update your game list and launch **Minecraft Bedrock** from Ports. The
   first run extracts the game — give it a few minutes.
4. Delete the APK from the `apk/` folder afterwards.

You can install several versions (drop each APK in `apk/` and launch once).
The main **Minecraft Bedrock** entry runs the newest installed version.

### 1.16.221.01

For the working GUI Scale slider, install 1.16.221.01 and use the separate
**Minecraft Bedrock 1.16** entry — it runs 1.16 with its own isolated world
(older clients cannot open newer worlds). On first launch, dismiss the Xbox
sign-in prompt (press **B**) to reach the menu; sign-in is not supported.
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
- **Audio** uses the launcher's PulseAudio backend (works on Knulli and
  ROCKNIX). Optional: drop a host (glibc aarch64) FMOD Engine
  `libfmod.so.12.0` from fmod.com into `minecraftbedrock/fmod/` to use real
  FMOD instead.
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
  (required for framebuffer/controller access on Knulli).

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

- Logs: `minecraftbedrock/log.txt` and `minecraftbedrock/weston_launch.log`.
- Black screen after a crash: restart EmulationStation over SSH
  (`/etc/init.d/S31emulationstation start`) or reboot.
- "Unable to locate asset: bootstrap.json": your APK's assets use the nested
  `assets/assets/` layout and something flattened it — re-run setup with the
  original APK (the bundled setup script preserves the layout).

## Source

The launcher is GPL-3.0. The complete modified source is provided as patch
files in `source_release/` (see its README for base commits and build
instructions) and as branch `rg34xxsp-port` on the forks under
https://github.com/DankMiimer (mcpelauncher-manifest, mcpelauncher-client,
game-window, libc-shim, linux-gamepad — recursive-clone the manifest fork to
build). Licenses for all shipped components: `minecraftbedrock/licenses/`.

## Credits

- The [minecraft-linux](https://github.com/minecraft-linux) project —
  mcpelauncher is the heart of this port.
- ImpressiveStay — the original R36S/RK3326 MCPE launcher port that started
  this.
- binarycounter — Westonpack/crusty, the graphics stack that makes libmali
  devices viable.
- The PortMaster team — runtime distribution and the porting ecosystem.
- Mojang Studios — Minecraft. Buy the game.

Port by DankMiimer.
