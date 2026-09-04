# Resource packs worth studying for the RG34XX-SP

Research checked 2026-09-04 for Bedrock 1.21.51.01, the installed no-RenderDragon
build, and a 720x480 display. These are candidates and design references; none
of these additional packs has been installed or benchmarked on the handheld.
Publisher version tags are evidence for choosing an experiment, not proof of
compatibility with this port. The implementation plan remains
[HANDHELD-UI-PLAN.md](HANDHELD-UI-PLAN.md).

## Shortlist

| Project and exact reference | What could help | Fit for our version |
|---|---|---|
| [Bedrock Tweaks source tag 5.2.2](https://github.com/BedrockTweaks/Files/tree/5.2.2) | Stronger inventory selection borders, colored hotbar selectors, lower shield/fire, and selective decorative-particle removal. Best modular reference. | Use this historical source snapshot. Release 5.2.1 updated packs to 1.21.50; 5.2.2 fixes several components. This is source for assembling selected features, not a single ready-made optimization pack. |
| [Controller Tooltip Selector 2.0.0](https://www.curseforge.com/minecraft-bedrock/addons/controller-tooltip-selector/files/4974226), AgentMindStorm | Nintendo/Switch-style controller prompts could better match the handheld's button labels. | Published for 1.20.50, with that minimum stated by its author. Needs 1.21.51 testing. Icon replacement does not remap buttons; prompts must match our actual mapping. |
| [Itsmooth, file 6248952](https://www.curseforge.com/minecraft-bedrock/addons/itsmooth/files/6248952), itsme64 | An optional 8x8 texture experiment to assess whether smaller textures help memory use or frame times. | This file explicitly lists 1.21.51 and 1.21.50. The author reports incomplete coverage and known bugs. Expect a simpler visual style; no measured FPS benefit on our device. |
| [VDX Legacy Bottom Chat UI 3.2.2](https://www.curseforge.com/minecraft-bedrock/addons/vdx-legacy-bottom-chat-ui/files/5974236), CrisXolt | A small example of relocating chat and handling message fading; useful when arranging a larger HUD. | Explicit 1.21.50 file, dated 2024-12-08. Test chat placement against our enlarged hotbar. It does not enlarge the whole UI. |
| [VDX Legacy Console UI](https://www.curseforge.com/minecraft-bedrock/texture-packs/vdx-legacy-console-ui/files/all), CrisXolt | Console-style screen layouts are a useful design reference for our controller-first interface. | The available files checked target newer releases. No matching 1.21.50 full-pack download was verified. Treat as a layout reference requiring adaptation, not a drop-in fix. |
| [Inventory Optimizer](https://www.curseforge.com/minecraft-bedrock/texture-packs/inventory-optimizer), ItzRiyo157 | Its author describes removing screen and flying-item animations, plus simplifying the recipe book. The animation approach is worth testing independently. | [File 7981070](https://www.curseforge.com/minecraft-bedrock/texture-packs/inventory-optimizer/files/7981070) lists 1.21.100 and newer, not our version. Study the mechanism and implement it against our vanilla UI. |
| [Console Aspects](https://www.curseforge.com/minecraft-bedrock/addons/console-aspects), AgentMindStorm | Controller navigation refinements, including inventory cursor wrapping, and removal of flying-item rendering during quick moves. | The current full pack targets newer Bedrock. Use navigation ideas as references. Its separate Item Icons companion carries an author warning about menu performance. |

Bedrock Tweaks' [5.2.1 release](https://github.com/BedrockTweaks/Files/releases/tag/5.2.1)
documents the 1.21.50 update; [5.2.2](https://github.com/BedrockTweaks/Files/releases/tag/5.2.2)
adds fixes. [5.2.3](https://github.com/BedrockTweaks/Files/releases/tag/5.2.3)
explicitly drops 1.21.50 and 1.21.60 support. The current website builder should
therefore not be our source for version-specific UI files.

## What the inspected Bedrock Tweaks files establish

These files were read directly from tag 5.2.2:

- [Hotbar-style inventory highlight](https://github.com/BedrockTweaks/Files/blob/5.2.2/resource_packs/files/gui/hotbar_style_inventory_slot_highlight/ui/ui_common.json)
  changes the selection texture and gives its bounds six extra pixels. This
  supports a small, targeted focus-visibility change; it does not scale slots.
- [No Pale Garden leaves particles](https://github.com/BedrockTweaks/Files/blob/5.2.2/resource_packs/files/unobtrusive/no_pale_garden_leaves_particles/particles/pale_oak_leaves_particle.particle.json)
  sets the manual emitter's maximum to zero. This is actual decorative-particle
  suppression, though its effect on total frame time remains unmeasured.
- [Unobtrusive rain splash](https://github.com/BedrockTweaks/Files/blob/5.2.2/resource_packs/files/unobtrusive/unobtrusive_rain/particles/rain_splash.particle.json)
  still allows 300 particles and retains motion/collision components. A less
  intrusive appearance does not establish lower simulation cost.

The [snapshot's license](https://github.com/BedrockTweaks/Files/blob/5.2.2/LICENSE)
permits modified/bundled reuse subject to its conditions, including no paid
access, retaining the notice, and crediting Vanilla Tweaks and Bedrock Tweaks
in publishing locations and `credits.txt`. Other shortlisted authors' pages
use All Rights Reserved; use those as design references unless reuse rights
are obtained. No third-party pack files have been added to the distributable.

## Changes to prioritize in our own packs

1. Keep the planned larger menu, inventory and HUD experiments. Add a clear
   selection border and readable controller prompts. None of the projects
   checked establishes a complete global-scale fix for our exact binary.
2. Add an optional reduced-menu-animation setting. Measure inventory opening
   and repeated quick moves. Preserve crafting access: Inventory Optimizer's
   published design leaves only search and nine recipe slots, which is a
   substantial tradeoff for ordinary survival play.
3. Test selective leaf/ambient-particle suppression in Handheld Effects.
   Evaluate lower shield/fire separately as screen-visibility improvements.
4. Compare Itsmooth with default textures as a separate profile. Inspect its
   UI/font overrides before combining it with Handheld UI, retaining readable
   text and icons. Smaller world textures do not solve tiny controls.
5. Integrate selected UI changes into one coherent pack. Overlapping HUD and
   inventory definitions need deliberate merging; enabling several complete
   UI overhauls together is not a substitute for integration.

## Lower priority

[Daniel's Sodium Options](https://www.planetminecraft.com/mod/daniel-s-sodium-options/)
was also checked at the user's suggestion. Its author describes a Java/Fabric
mod for Sodium; it cannot load in this Bedrock client. The listing supplies no
implementation details or benchmarks supporting its performance claims, so it
does not add a concrete optimization technique to this plan.

[FPS Optimizer](https://www.curseforge.com/minecraft-bedrock/texture-packs/fps-optimizer-fps-boost)
describes particle and animation reductions, but also changes fog and other
systems. It is a secondary effects reference; the exact files and renderer
assumptions need inspection before use with our legacy renderer. Broad FPS
claims are not measurements of this port.

[Ty-el's Settings Overlay](https://www.curseforge.com/minecraft-bedrock/texture-packs/the-ty-els-settings-overlay-ui-pack)
requires touch and its author discourages use on low-end devices because it
keeps a settings screen rendered over the HUD. That makes it a poor fit here.

Follow the existing plan's same-scene benchmarks and controller checks before
promoting any candidate to a default. This research adds no proven FPS gain
and does not change the recovered Ports launcher.
