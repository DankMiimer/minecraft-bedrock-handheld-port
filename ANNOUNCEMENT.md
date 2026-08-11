# Archived v1.6 announcement

> Historical document. It describes the v1.6 release and must not be used as
> current installation guidance. See [`README.md`](README.md) for v2.x.

# Minecraft Bedrock Edition — native port for ARM handhelds

Minecraft Bedrock running **natively** (no emulation, no streaming) on ARM
Linux handhelds, via minecraft-linux's **mcpelauncher**. The package includes
the aarch64 EGLUT/Weston path and the 32-bit armhf SDL path for
RK3326/R36S-class devices.

**You bring your own legally-owned Minecraft Bedrock APK — no game files are
included or distributed.**

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Tested and working

- **Anbernic RG34XX-SP** (Allwinner H700) on **muOS** and **Knulli** —
  including sound on muOS 2601
- **Anbernic RG DS** (Rockchip RK3566, dual screen) on **ROCKNIX**
- **LAN multiplayer works across devices** — I've had the RG34XX-SP and the
  RG DS in the same world at the same time.

Should also run on other H700-family muOS or Knulli devices (RG35XX-H / Plus
/ SP 2024, RG40XX, etc.), other aarch64 ROCKNIX devices, and
RK3326/R36S-class armhf PortMaster setups. Reports welcome — if your
controller isn't mapped, the port auto-generates a mapping and logs it so it
can be added.

## Highlights

- **One launcher entry with two version tracks:**
  - **1.20.x** (1.20.15 / 1.20.51 / 1.20.62) — modern gameplay.
  - **1.16.221.01** — has a **working GUI Scale slider**, so you get a
    properly sized UI at native resolution (newer versions lock it small on
    these screens). On tested devices it runs perfectly without stutters;
    choose it from **Versions** and it gets its own isolated profile.
- **Update from the launcher** — the old separate Update entry is now inside
  the main menu.
- **Auto controller mapping** — unknown gamepads get a sensible default at
  launch, no config needed.
- **Dual-screen aware** — on the RG DS the touchscreen is mapped to the game
  screen automatically.
- **Performance mode** — CPU/GPU clocks are boosted while playing and
  restored on exit; on 4-core devices a measured thread layout cuts stutter.
- Supports aarch64 devices and armhf RK3326/R36S-style PortMaster setups.

## Install

1. Unzip **onto your SD card** — at the root of the card (or network share)
   that holds your `roms`/`ROMS` folders. One zip covers muOS, Knulli,
   ROCKNIX, and R36S-style PortMaster layouts.
2. Put your own Bedrock APK (single APK, or Google Play splits together) into
   `ports/minecraftbedrock/apk/`, matching your device ABI.
3. Refresh your game list and launch **Minecraft Bedrock** from Ports. First
   run extracts the game (a few minutes), then delete the APK.
4. For the big-UI version, install a 1.16.221.01 APK the same way, open
   **Minecraft Bedrock**, and pick it from **Versions**.

The 64-bit path needs the `weston_pkg_0.2` runtime — it downloads
automatically on first launch if you have WiFi, or you can provide a
compatible runtime manually (muOS users can place it under
`MUOS/PortMaster/libs`). The R36S/armhf path uses the SDL client.
~2 GB free space for game assets.

## Release hygiene

- No Minecraft APKs, extracted libraries, worlds, profiles, or assets are
  included.
- GPL source patches, license texts, credits, support instructions, trademark
  notes, and a changelog are included with the release materials.
- The zip's SHA-256 is published in `SHA256SUMS.txt` and on each GitHub
  release page.

## Notes

- No Xbox Live / Marketplace sign-in (dismiss the first-run prompt with **B**);
  local worlds and LAN work.
- No on-screen keyboard — set names from a PC if needed.
- 1.16 and 1.20 can't share worlds or LAN with each other (different game
  versions).

## Legal / source

No Minecraft content is included; you must own the game and supply your own
APK. The launcher is GPL-3.0 — full modified source (branch `rg34xxsp-port`):
https://github.com/DankMiimer/mcpelauncher-manifest/tree/rg34xxsp-port

## Thanks

The minecraft-linux project (mcpelauncher), ImpressiveStay (original
RK3326 MCPE port this started from), binarycounter (Westonpack/crusty), and
the handheld Linux porting community. Minecraft © Mojang Studios — buy the game.

Port by DankMiimer.
