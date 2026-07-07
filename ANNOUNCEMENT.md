# Minecraft Bedrock Edition — native port for aarch64 handhelds

Minecraft Bedrock running **natively** (no emulation, no streaming) on ARM
Linux handhelds, via minecraft-linux's **mcpelauncher** with a custom EGLUT
game-window backend on a Weston/crusty graphics stack.

**You bring your own legally-owned Minecraft Bedrock APK — no game files are
included or distributed.**

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Tested and working

- **Anbernic RG34XX-SP** (Allwinner H700) on **Knulli**
- **Anbernic RG DS** (Rockchip RK3566, dual screen) on **ROCKNIX**
- **LAN multiplayer works across devices** — I've had the RG34XX-SP and the
  RG DS in the same world at the same time.

Should also run on other H700-family Knulli devices (RG35XX-H / Plus / SP
2024, RG40XX, etc.) and other aarch64 ROCKNIX devices. Reports welcome — if
your controller isn't mapped, the port auto-generates a mapping and logs it
so it can be added.

## Highlights

- **Two version tracks:**
  - **1.20.x** (1.20.15 / 1.20.51 / 1.20.62) — modern gameplay.
  - **1.16.221.01** — has a **working GUI Scale slider**, so you get a
    properly sized UI at native resolution (newer versions lock it small on
    these screens). On tested devices it runs perfectly without stutters.
    Runs from its own entry with a separate world.
- **Auto controller mapping** — unknown gamepads get a sensible default at
  launch, no config needed.
- **Dual-screen aware** — on the RG DS the touchscreen is mapped to the game
  screen automatically.
- **Performance mode** — CPU/GPU clocks are boosted while playing and
  restored on exit; on 4-core devices a measured thread layout cuts stutter.
- Not 32-bit compatible (needs an aarch64 device + GLES 3).

## Install

1. Unzip into your ports folder (`/roms/ports/` — Knulli:
   `/userdata/roms/ports/`).
2. Put your own **arm64** Bedrock APK (single APK, or Google Play splits
   together) into `minecraftbedrock/apk/`.
3. Refresh your game list and launch **Minecraft Bedrock** from Ports. First
   run extracts the game (a few minutes), then delete the APK.
4. For the big-UI version, install a 1.16.221.01 arm64 APK the same way and
   use the **Minecraft Bedrock 1.16** entry.

Needs the `weston_pkg_0.2` runtime — it downloads automatically on first
launch if you have WiFi, or you can provide a compatible runtime manually.
~2 GB free space for game assets.

## Release hygiene

- No Minecraft APKs, extracted libraries, worlds, profiles, or assets are
  included.
- GPL source patches, license texts, credits, support instructions, trademark
  notes, and a changelog are included with the release materials.
- SHA-256 for `minecraftbedrock-1.3.zip`:
  `a3c221efefa52f4337c8431e5b8a685bb3af2662df810852dfd4612146481fca`

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
