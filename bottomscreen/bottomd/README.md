# bottomd — RGDS Minecraft companion

`bottomd` is the 640×480 lower-screen UI for the RGDS edition. Its layout is
inspired by the AYN Thor Minecraft second-screen projects: a persistent status
stack, one large working area, and five equal Minecraft-style tabs along the
bottom.

The tabs are:

- **HUD** — centered local-world terrain map, player marker, coordinates,
  direction, zoom, recenter, dimension, FPS, health and hunger snapshots.
- **Chat** — independent chat history and touch keyboard; never a game mirror.
- **Items** — independent 36-slot inventory and craftable-recipe pane;
  automatically selected when a supported build reports an open container.
- **Input** — 3×3 shortcuts for tabs, map controls, screen swap and keyboard.
- **Settings** — in-session toggles for the status stack, automatic Items tab,
  day/night map tint and player-following map.

No Minecraft textures or other game assets are distributed. At runtime the
companion indexes and loads PNGs from the selected user-supplied Minecraft
installation; procedural drawing remains the fallback.

## Data sources and limits

| UI data | Source | Behavior |
|---|---|---|
| position, heading, frame timing, remote-world state, screen-open hint | native launcher telemetry shared memory | live |
| health, hunger, dimension, world time, spawn | active world's LevelDB `player.json` snapshot | updates when Bedrock flushes and `bedrockmap` republishes |
| local terrain | `bedrockmap` raw tile cache | live incremental map; never used for a remote LAN world |
| inventory, crafting, chat | versioned native companion state/command shared memory | independent UI; unsupported actions are read-only and rejected |
| UI and item textures | selected version's installed resource packs | paths are indexed at launch; image bytes never enter the port |
| companion touch | local page hit-testing | never forwarded to the game; screen-swap touch injection is separate |

The first game-side profile targets the exact original `1.21.51.01` arm64
library. Version name, SHA-256, RTTI, vtable target and function prologue must
all match before the HUD hook is installed. Capabilities are advertised one by
one; the UI does not assume that inventory writes or chat sends are safe.

## Build and test

```sh
make bottomd
make check check-daynight check-worldinfo \
  check-pages check-independent check-modes
```

`bottomd-wayland` is the RGDS target. It needs Wayland client headers,
`wayland-scanner`, `wayland-protocols`, and an arm64 Wayland client library for
cross-builds:

```sh
make bottomd-wayland CC=aarch64-linux-gnu-gcc \
  WAYLAND_LIBS=/path/to/arm64/libwayland-client.so
```

The `ppm` backend is deterministic visual-test output; `fbdev` is retained for
diagnostics. RGDS production uses `wl_shm`/`xdg-shell` and Sway places
`app_id=bottomd` on the discovered lower output.

## Runtime

```text
bottomd [--backend ppm|fbdev|wayland] [--outdir DIR] [--frames N]
        [--fps N] [--zoom PX_PER_BLOCK]
```

Important environment variables:

- `MCPE_TELEMETRY_SHM`, `BOTTOMD_COMPANION_STATE_SHM`,
  `BOTTOMD_COMPANION_CMD_SHM`
- `BOTTOMD_RESOURCE_INDEX`, `BOTTOMD_ITEM_INDEX`
- `BOTTOMD_TILES`, `BOTTOMD_PLAYER_JSON`, `BOTTOMD_WAYPOINTS`
- `BOTTOMD_PAGE=hud|chat|items|input|settings`
- `BOTTOMD_AUTO_ITEMS=0|1`, `BOTTOMD_SHOW_STATUS=0|1`,
  `BOTTOMD_NIGHT_TINT=0|1`
- `BOTTOMD_OSK_SHOW_CMD`, `BOTTOMD_UINPUT`, `BOTTOMD_INJECT_TOUCH_ID`
- `BOTTOMD_TOP_OUTPUT`, `BOTTOMD_BOTTOM_OUTPUT`, `BOTTOMD_JOYPAD`
- `BOTTOMD_PANEL_TOP`, `BOTTOMD_PANEL_BOTTOM`

SELECT swaps the game and companion surfaces. Physical panel discovery and raw
touch routing are dynamic; there are no fixed `DSI-*`, Goodix, or evdev names.
