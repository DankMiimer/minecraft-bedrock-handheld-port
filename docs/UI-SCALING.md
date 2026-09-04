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
| Answers to | stock scale: real render surface; individual controls: JSON layout overrides | the reported Android DPI |
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

## JSON UI: only the render surface moved the stock layout in these tests

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
enlarges the result. This is the only measured launcher setting that enlarges
the stock JSON UI on 1.21; it does not rule out changing the layout itself with
a resource pack. See [the handheld UI proposal](HANDHELD-UI-PLAN.md) for the
1.21.51.01 asset inspection and the native HUD renderer limitation.

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

The 2026-09-04 resource-pack experiment confirmed that individual menu buttons,
labels and hotbar slots can be enlarged at native 720x480. The prototype is in
`portmaster/minecraftbedrock/minecraftbedrock/packs/handheld-ui/`, with opt-in
activation and an exact version/library guard in `handheld_ui.py`. Its text
overrides also enlarge label bounds: increasing font scale alone clipped the
main menu labels against their original 10-unit maximum height.

In a separate simultaneous HUD probe, three `heart_renderer` instances with
sizes `[1,1]`, `[1.5,1.5]` and `[16,16]` produced identically sized hearts. The
probe was removed from the usable pack. This establishes that changing this
renderer's nominal size is insufficient; it does not establish that every
possible native rendering approach is impossible. Existing health feedback
remains intact while the client-side scaling investigation below remains open.

The remaining JSON escape route is closed too. Rebuilding the status icons as
ordinary image controls would need the player's state as bindings, and this
build exposes none: `heart_renderer`, `hunger_renderer`, `armor_renderer` and
`bubbles_renderer` are all `"type": "custom"` carrying only visibility bindings
(`#show_survival_ui`, `#is_armor_visible`), and no `#health`, `#hunger`,
`#absorption`, `#armor_value` or air-supply binding name occurs anywhere in the
version's `vanilla/ui` tree. So health, hunger, armour and bubbles keep their
stock size at native resolution no matter what a resource pack does. Their
position is stock as well: in this HUD mode `not_centered_gui_elements` anchors
hearts and armour to `top_left [2,2]` and hunger and bubbles to
`top_right [-2,2]`, which is why they sit in the corners rather than above the
hotbar. UI zoom is the only shipping setting that enlarges them, and the
viewport override below is the only way to do it without giving up sharpness.

## Scale factors must be integers

Two rules came out of the 2026-09-04 device iteration, and both show up as
softness rather than as anything obviously broken:

- **Text.** The UI font is a bitmap font. A `font_scale_factor` of 1.5 lands
  glyph edges on half-pixels and reads as blurry and "not like Minecraft"; 2 and
  3 stay crisp. The first prototype scaled the menus by 1.5 and this was the
  visible result.
- **Item icons.** Item art is 16x16, so an `item_icon` size that is not a
  multiple of 16 resamples. 32 and 48 are sharp; 40 and 50 are not. This is what
  makes hotbar sizing coarse: between a 2x and a 3x slot there is no sharp
  intermediate step.

Scaling a whole screen by one integer factor also preserves vanilla proportion,
which is what makes an enlarged screen still look like Minecraft. Derive each
number from this build's own stock value rather than from the previous
override, or the roundings compound.

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

### Phase 1: which query does 1.21 actually lay out from?

The `MCPE_REPORTED_DISPLAY_SCALE` result above is easy to over-read. That build
lied in `MainActivity::getScreenWidth`, the Android display-metrics route, and
nothing moved -- which says the display metrics are ignored, not that the
approach fails. Two other functions report the drawing surface, both reading the
same `GameWindow::getWindowSize`, and neither had been touched:

| Reports the surface | Where | Lied to in that test |
|---|---|---|
| `eglQuerySurface` (`EGL_WIDTH`/`EGL_HEIGHT`) | `mcpelauncher-client/src/fake_egl.cpp` | no |
| `ANativeWindow_getWidth` / `getHeight` | `mcpelauncher-client/src/fake_window.cpp` | no |
| `getScreenWidth/Height`, `getDisplayWidth/Height` | `src/jni/main_activity.cpp` | yes, no effect |

`MCPE_UI_LAYOUT_SCALE` (in `src/ui_layout_scale.h`, from the client patch)
shrinks exactly the first two answers and nothing else. `1.5` reports a surface
two thirds the real size. Unset, empty, unparsable, `<= 1.0` or `> 4.0` all mean
off, so a default build is unchanged; `weston_launch.sh` forwards the variable
only when it is explicitly set.

**This is a diagnostic, not a usable mode.** Rendering is deliberately not
corrected, so the game draws into part of the panel and pointer mapping keeps
the old factor. It answers one question -- does the interface lay out coarser? --
before any of the viewport and input work is written. If the UI does not change
size, the surface-reporting route is dead and only the display scaler remains.

#### Result, RG34XX-SP / Knulli, 2026-09-04: the route works

Measured on `1.21.51.01-972105101-arm64` at `MCPE_UI_LAYOUT_SCALE=1.5`, panel
720x480, density 1, launcher UI zoom Off.

    [UIScale] eglQuerySurface EGL_WIDTH  -> 480 (real 720, scale 1.500)
    [UIScale] eglQuerySurface EGL_HEIGHT -> 320 (real 480, scale 1.500)
    [UIDiag]  getScreenWidth  -> 720

The engine drew its whole frame, world and interface together, into a measured
**480x321** region of the 720x480 panel: the surface size it was told about.
`getScreenWidth` still answered 720 throughout, so the display-metrics route was
not involved and the cause is isolated to the EGL/native-window query. That is
the lever the `MCPE_REPORTED_DISPLAY_SCALE` attempt never pulled.

**The native status renderers follow the surface**, which is the part that
matters for health and hunger. The heart row measured identically in both modes
-- 79x7 px starting at x=3 -- so it is drawn in surface units, not in panel
pixels. Against a 720-wide surface that is 11.0% of the width; against a
480-wide surface it is 16.5%. Stretching the viewport by the same 1.5 therefore
lands the hearts at about 118 physical pixels, and a resource pack is not
involved at any point. This is the only route found so far that enlarges them.

Two consequences for the handheld-ui pack, which composes multiplicatively with
this and must come down when a surface scale is in use:

- Its 3x hotbar is 546 units wide, which does not fit a 480-wide surface, and
  the ninth slot was visibly clipped. At a 1.5 surface scale the pack wants its
  2x hotbar (364 units) instead, which lands at the same 546 physical pixels.
- Sharpness improves rather than degrades: a 2x item icon is 32 units, and
  32 x 1.5 = 48 physical pixels, an exact 3x of the 16x16 source. The viewport
  scale multiplies geometry before rasterisation, so this is not an image
  upscale and does not soften the way launcher UI zoom does.

The client override is reachable on this hardware. The device reports
`renderer=legacy_gles_no_renderdragon` on `OpenGL ES 3.2`, which is the ES2 path
in `main.cpp`: `MinecraftUtils::setupGLES2Symbols(fake_egl::eglGetProcAddress)`
builds the fake `libGLESv2.so` by calling `eglGetProcAddress`, and that consults
`hostProcOverrides` first. So the commented `glViewport` skeleton in
`FakeEGL::setupGLOverrides()` intercepts the real game's calls, and phase 2 has
somewhere to live. The glcore path reaches the same map through
`GLCorePatch::installGL`.

Phase 2 scales `glViewport`/`glScissor` back up so drawing covers the panel
again, guarded on framebuffer 0 being bound -- the `LD_PRELOAD` trace above
found no offscreen target is ever allocated, so the guard should always hold
here, but it is cheap to enforce through a `glBindFramebuffer` override rather
than assumed. `glGetIntegerv(GL_VIEWPORT)` readback needs checking too. Phase 3
applies the inverse factor to pointer input.

This would enlarge JSON UI and shrink nothing, so Ore UI screens would grow with
it -- they need the opposite treatment. cohtml is the one library this binary
still exports symbols for (`cohtml::SystemImpl::CreateView(const ViewSettings&)`
is in `.dynsym`, where no Mojang symbol is), so an Ore-UI-only viewport override
is reachable by `dlsym` without offset patching. Building the client is a CI
job: the `clients` matrix in `.github/workflows/release.yml`.
