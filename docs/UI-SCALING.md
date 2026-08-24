# UI scaling

Measured on the reference RG34XX-SP (Knulli Scarab, H700, Mali-G31, 720x480
panel) against `1.21.51.01-972105101-arm64` and `1.16.221.01-971622101-arm64`.

Bedrock draws its interface with two independent systems, and they answer to
different things. Treating them as one is what made UI work on this port
frustrating for so long: a change would appear to do nothing, then turn out to
have moved two screens and nothing else.

| | JSON UI | Ore UI |
|---|---|---|
| Screens | HUD, inventory and containers, chat, pause, main menu, world list | Create New World, death, sign-in, settings tabs, achievements |
| Drawn by | the engine | cohtml |
| Answers to | the real render surface only | the reported Android DPI |
| Resource packs | can override | cannot touch it at all |

## Ore UI: the client density setting, and why everything "only affected two screens"

The port used to write `scale=2` into `mcpelauncher-client-settings.txt`
(upstream default is 1). That value reaches the game only as an Android DPI --
`getPlatformDpi` returns `96 * 2 * scale` -- and **1.21.51.01 never asks for
it** when laying out JSON UI. So every measurement taken against the HUD or the
main menu showed it doing nothing, and it looked inert.

cohtml does read the DPI. At `scale=2` the Ore UI screens were rendered at
double scale and overflowed the panel: on Create New World the title was
clipped and the game-mode row fell off the bottom; on the death screen the text
ran past both edges and RESPAWN collided with "Game Menu". Both got worse with
the UI zoom, because a smaller surface enlarges them further.

`scale=1` fixes both, on 1.21.51.01 and 1.16.221.01 alike -- confirmed by
screenshot on each. The port now leaves the setting at its stock value, and
`mcpe_apply_arm64_defaults` documents why. Raise `MCPE_UI_DENSITY_SCALE` only
to make Ore UI screens *bigger*; it cannot enlarge anything else.

## JSON UI: only the render surface moves it

Every other lever was measured against the start screen, whose green Play
button is JSON UI. Its width as a fraction of the framebuffer is the effective
UI scale; a control run repeated at the end of the matrix reproduced the
reference number exactly.

| Setting under test | Play button | Share of screen width | Effect |
|---|---|---|---|
| Control: 720x480, `scale=2` | 146 px | 20.3% | reference |
| client `scale` 1 / 3 | 146 px | 20.3% | none |
| `gfx_guiscale_offset` +1 / -1 | 146 px | 20.3% | none |
| `gfx_pixeldensity=4` | 146 px | 20.3% | none |
| `MCPE_REPORTED_DISPLAY_SCALE=0.5` | 146 px | 20.3% | none |
| `gfx_resizableui=1` | 146 px | 20.3% | none |
| `gfx_upscaling` + `upscaling_enabled` + `upscaling_percentage=50` | 146 px | 20.3% | none |
| **fb 576x384** | 146 px of 576 | **25.3%** | **1.25x** |
| **fb 480x320** | 146 px of 480 | **30.4%** | **1.5x, 55% fewer pixels** |
| fb 600x400 | 146 px | 20.3% | mode does not hold; renders native |
| fb 360x240 | — | — | geometry and content disagree; unusable |

The button is exactly 146 physical pixels wide at every surface size tested.
The engine is not choosing a different scale for a smaller surface; it keeps the
same scale and the panel scaler enlarges everything.

`1.21.51.01` never calls `getPixelsPerMillimeter` -- its log carries only
`getScreenWidth/Height` and `getDisplayWidth/Height` -- while `1.16.221.01` on
the same device logs `getPixelsPerMillimeter -> 15.118 (scale=2.000)`.
`MCPE_REPORTED_DISPLAY_SCALE` was removed from the client patch after measuring
that the lie lands (`getScreenWidth -> 360`) and the rendered pixels do not
move: 1.21 lays out from the real EGL surface, which `fake_window.cpp` reports
truthfully.

## UI zoom

Launcher menu, **Settings** -> **UI zoom**: `Off`, `1.25x` (576x384 here) or
`1.5x` (480x320 here). The port renders below the panel and the display scaler
enlarges the result, which is the only lever that moves JSON UI on 1.21.

At 1.5x the HUD, inventory, chat and menus are half again as large and the GPU
draws 55% fewer pixels, so it is also the cheapest way to raise the frame rate.
The costs are a softer image and **larger Ore UI screens**, which are already
tight at native size -- if world creation or the death screen feel cramped, that
is the trade, and `Off` restores them.

`fbset` cannot be trusted here: every size tested survives the call and an
immediate read-back while the device is idle, and `/sys/class/graphics/fb0/modes`
is a log of previously requested modes rather than a capability list. What
separates the sizes that hold from the ones that do not is alignment --
480x320 and 576x384 are multiples of 16 and survive a session, 600x400 reverts
to the panel size once the game has a surface, and 360x240 leaves the geometry
and the rendered content disagreeing. `mcpe_fb_mode_aligned` enforces that and
the read-back is kept as a second gate.

## Screenshots

**menu+L3** writes a PNG to `ports/minecraftbedrock/screenshots/`. There is no
compositor screenshot key on the framebuffer path, so `screenshot_watch.py`
reads the evdev nodes alongside the client.

Pads whose printed labels disagree with the `BTN_` names their driver sends need
a `LAYOUTS` entry. On the RG34XX-SP the labels sit one place off -- L3 arrives as
`0x139`, R3 as `0x13c`, L2 as `0x13a`, R2 as `0x13b` -- and one press of MENU
emits both `0x138` and `0x162`. Map new hardware by running with
`MCPE_SCREENSHOT_DEBUG=1`, which logs every code and the live held-set.
`MCPE_SCREENSHOT_COMBO=menu+r3` overrides the chord in the pad's own labels and
`MCPE_SCREENSHOTS=0` disables it.

## What a mod could still do

The renderer draws the entire frame into the default framebuffer: an
`LD_PRELOAD` shim over the host GL library counted 240000+ draw calls, every one
into framebuffer 0 at the full viewport, with **no offscreen render target ever
allocated** -- no `glRenderbufferStorage`, no null-data `glTexImage2D`, no
`glFramebufferTexture2D` -- in menus and in a loaded world alike.

That means the UI could be enlarged without giving up world resolution:
`mcpelauncher` owns both places the game learns its surface size
(`ANativeWindow_getWidth/getHeight`, `eglQuerySurface`) and hands the game its
GL entry points through `fake_egl::hostProcOverrides`, where upstream already
leaves a commented `glViewport` override as a skeleton. Reporting a smaller
surface and scaling `glViewport`/`glScissor` back up would lay the UI out
coarser while every draw still rasterises across the full panel. The viewport
override must apply only while framebuffer 0 is bound, and pointer input needs
the inverse factor.

This would enlarge JSON UI and shrink nothing, so Ore UI screens would grow with
it -- they need the opposite treatment. cohtml is the one library this binary
still exports symbols for (`cohtml::SystemImpl::CreateView(const ViewSettings&)`
is in `.dynsym`, where no Mojang symbol is), so an Ore-UI-only viewport override
is reachable by `dlsym` without offset patching. Building the client is a CI
job: the `clients` matrix in `.github/workflows/release.yml`.
