# Handheld UI and optional visual reductions for 1.21.51.01

Proposal based on the installed RG34XX-SP build and the supplied OptiFine RK
archive, inspected 2026-09-04. The first UI prototype is now implemented under
`portmaster/minecraftbedrock/minecraftbedrock/packs/handheld-ui/`. Larger main
buttons and hotbar slots were observed on the device; the simultaneous heart
renderer sizing probe showed no change at 1x, 1.5x or 16x dimensions. The wider
screen-coverage and effects work below remains a plan, not a measured FPS gain.

## Recommended approach

Build two independent resource packs: **Handheld UI** for readable controls,
and **Handheld Effects** for optional visual reductions. Keep the world at
720x480, launcher UI zoom off, and client density at 1. This preserves world
sharpness and the existing Ore UI fix while allowing JSON layouts to change.

Start with a small main-menu and HUD experiment before implementing every
screen. Ordinary JSON controls have explicit dimensions and font scaling, but
some HUD elements use native renderers. A resource pack is a promising layout
solution, not yet a proven universal UI-scale replacement.

Additional version-specific candidates and design references are recorded in
[MOD-SHORTLIST.md](MOD-SHORTLIST.md), including Bedrock Tweaks 5.2.2, controller
prompts, console layouts, reduced inventory animations and 8x8 textures.

## What the supplied OptiFine pack actually does

The supplied ZIP contains a nested `OptiFineRK_v5.3.1.mcpack`, whose root folder
is `OptiFineRK v5.3.1`. It contains 668 files. Its manifest declares only a
resource module, with three optimization subpacks. The nested pack SHA-256 is
`ca40f31e678daae6bef5369b52c1270f943534b80f9e594670ad733c27861119`.

The [ModsGamer listing](https://modsgamer.com/minecraft/optifine-rk-v5-3-1-official)
targets 1.20.30.21. The [FMCPE listing](https://fmcpe.com/mods/1013-optifine-rk-addon.html)
offers a download labelled 1.19.50. Neither establishes compatibility with our
1.21.51.01 binary. The supplied archive was inspected directly; the second
download was not needed for this design.

| Mechanism found in the archive | Useful lesson for this port |
|---|---|
| `ui/start_screen.json`, `hud_screen.json`, settings and inventory overrides | Change individual layouts, button dimensions and text; preserve current bindings. |
| 90 / 107 / 121 particle JSON files in the three subpacks | Make effects optional and targeted. Many files set instant particle counts or manual emitter limits to zero. |
| Subpack `textures/flipbook_textures.json` | Repeated frame zero and very large frame durations effectively freeze selected animations. |
| Vegetation/sky textures, fog, GLSL and particle-material overrides | These change appearance and depend on the renderer. They need separate testing on our no-RenderDragon build. |
| `scripts/general_optimization.ml` and `water_optimization.ml` | These are not executable Bedrock optimization modules. The resource-only manifest supplies no script entry point; do not count them as performance work. |

The archive credits PhantomRK and several other contributors. Use its
techniques as inspiration and author our own small overrides. Do not ship the
old UI tree, branding, shader files or unverified optimization claims.

## Exact targets in our installed build

The inspected version is `1.21.51.01-972105101-arm64`, native-library SHA-256
`45382be72491ec2cbe5dd4d1262989ad894b8fc611e5cbc16141d04171510927`.
Its vanilla definitions are under
`versions/<version>/assets/assets/resource_packs/vanilla/` on the device.

These are design targets, not a blanket multiplication of every JSON number:

| Screen/control | Observed definition | Proposed first experiment |
|---|---|---|
| Start menu | `start.main_buttons_panel` is 150 units wide; `start.stacked_row` is 32 high | Try 225-wide panels and 48-high rows, with 1.5x button text. Reflow the logo and profile area if needed. |
| Text buttons | `ui/ui_template_buttons.json` exposes `$button_font_scale_factor` | Set it on the intended button instances, and enlarge their label bounds and hit areas together. |
| Hotbar slots | `hud.gui_hotbar_grid_item` is 20x22; its nested item icon is 16x16 | Try 30x33 slots with 24x24 icons, matching backgrounds, selection borders, counts and durability bars. |
| Inventory cells | `common.container_item` is 18x18 with a 16x16 item renderer | Try 27x27 cells and 24x24 icons; resize grids and their enclosing panels together. |
| Recipe book and containers | Crafting grids, recipe cells and container panels have their own dimensions | Reflow each screen and its scroll area. Preserve slot counts, collection bindings and controller focus. |
| Hearts and other HUD artwork | `hud.heart_renderer` is a custom native renderer with a nominal 1x1 size | Test separately. A larger nominal size may leave the artwork unchanged. |

The existing vanilla pocket inventory already uses 28x28 cells and 24x24
icons, which is a useful layout reference. It does not prove that switching
the entire game to pocket mode will solve controller navigation or HUD scale.

Do not scale UV coordinates, atlas dimensions, collection indices, animation
timings or grid row/column counts. Those describe assets and game state, not
the visual size of the controls.

Implement minimal namespace/control overrides using the installed definitions.
Keep the game's textures, actions, visibility bindings, collection names and
focus identifiers. Enlarge both the visuals and the corresponding input area.
Use local variables for common dimensions; do not invent a global engine zoom
property. Retain all necessary buttons, including sign-in and world actions.

## The HUD and Ore UI boundary

Test the native hotbar, heart, hunger, armour, air and XP renderers early. If
they honour their parent dimensions, include them in the pack. If they ignore
those dimensions, test whether the current JSON exposes enough state to build
equivalent image controls. Do not assume it exposes health, absorption,
flashing and status states just because it exposes visibility.

If the state or scaling is unavailable, the complete fix needs the separate
launcher/client viewport experiment described in [UI-SCALING.md](UI-SCALING.md).
That route must account for framebuffer bindings, scissors, pointer input and
Ore UI density, and remains unimplemented. The existing lower-resolution UI
zoom is the measured fallback meanwhile.

Standard JSON resource-pack overrides do not resize the cohtml/Ore UI screens.
Keep `MCPE_UI_DENSITY_SCALE=1`; increasing Android DPI previously enlarged
world-creation/death screens without helping JSON UI. Treat individual Ore
screens according to the actual installed build, not a generic list of screens
from a different Bedrock release.

## Optimization priorities

Begin with a conservative effects profile and test one category at a time:

1. Reduce ambient smoke, decorative portal/enchanting effects and rain splashes.
   Preserve combat feedback, block breaking, fishing cues and bubble-column
   direction until there is an explicit reason to remove them.
2. Offer static or slower decorative texture animations separately. Keep water,
   lava and fire identifiable. Generate the modified animation list from this
   version's vanilla list so unrelated/new atlas entries remain intact.
3. Evaluate a static menu background or reduced preview rendering only if menu
   frame-time measurements show useful savings. Retain dressing-room access.
4. Leave shader, fog, water and material changes for separate A/B experiments.
   In particular, do not import the old `particles.material` wholesale.

Use the emitter component appropriate to each effect: manual emission is
requested by the game, while steady emission has a spawn rate. Lowering a
manual emitter's maximum is a population cap, not a guaranteed proportional
reduction in emission rate. See the official
[manual emitter reference](https://learn.microsoft.com/en-us/minecraft/creator/reference/content/particlesreference/particlecomponents/minecraftemitter_rate_manual?view=minecraft-bedrock-stable)
and [particle component reference](https://github.com/MicrosoftDocs/minecraft-creator/blob/main/creator/Reference/Content/ParticlesReference/ParticleComponentList.md).

Keep the existing measured launcher settings: version-specific frame cap,
memory budget, async texture loading and multithreaded rendering. Avoid adding
duplicate controls that the launcher immediately rewrites. Resource packs
cannot replace engine scheduling, chunk streaming or simulation optimizations.

The August block-break experiment already showed that removing block debris
did **not** fix the black rectangle. Do not reintroduce that workaround under
an optimization label; see [TESTING.md](../TESTING.md).

## Packaging and validation

Use manifest format 2, a resource module, original UUIDs and
`min_engine_version: [1, 21, 50]`. This is a minimum, not an exact-version lock;
the launcher must separately gate any automatic activation by the tested
version/fingerprint. See the official
[manifest reference](https://learn.microsoft.com/en-us/minecraft/creator/reference/content/addonsreference/packmanifest?view=minecraft-bedrock-stable).

Place each pack under the resolved profile's
`mcpelauncher/games/com.mojang/resource_packs/` and enable it globally so it
reaches the main menu. Resolve the existing shared-data symlinks rather than
using the Android archive's absolute directory. Update only our entries in
`global_resource_packs.json`, preserving every other pack. Back up activation
state and provide an Off action outside Minecraft. Switching to 1.16 must not
leave the 1.21 UI pack active in the shared default profile.

Validation order:

1. Screenshot the unchanged main menu at 720x480, then the minimal menu patch
   at the same resolution and density. Check all buttons with the controller.
2. Probe HUD renderer sizing in a disposable survival world. Include damage,
   hunger, armour, drowning, XP, stack counts and durability.
3. Check inventory, crafting, chest, furnace, trade, pause and chat. Check focus,
   scroll limits and text clipping, plus world creation and death for regressions.
4. Benchmark effects with the same world, view, warmup, resolution and cap:
   baseline, effects only, UI only, then both. Compare median and p95/p99 frame
   times, not just average FPS. Smoke, rain, underwater and Nether scenes need
   explicit coverage. No FPS gain is claimed until these comparisons exist.
5. Verify Off, game-version switching and failure recovery without modifying
   worlds or deleting user packs.

The UI milestone is now complete and confirmed on the device: main menu, pause
menu, Pocket inventory, selected-item name and hotbar are all enlarged and
accepted at native 720x480. Everything is scaled by an integer factor derived
from this build's own stock values - menus and inventory 2x, hotbar 3x -
because the bitmap font and the 16x16 item art both resample at fractional
factors. See [UI-SCALING.md](UI-SCALING.md) for those two rules and
[TESTING.md](../TESTING.md) for the measured figures.

The native status renderers are closed as out of reach for a resource pack:
health, hunger, armour and bubbles ignore their container size and expose no
state bindings, so they can be neither resized nor reimplemented in JSON. Their
corner placement is stock. Enlarging them needs either launcher UI zoom, which
enlarges everything and softens the image, or the client viewport override.
That override is now the single remaining item for this part of the UI. The
wider acceptance matrix - durability, armour/air/XP, containers and trading,
other languages, version switching - and the whole effects/performance matrix
remain open, and no FPS gain is claimed.
