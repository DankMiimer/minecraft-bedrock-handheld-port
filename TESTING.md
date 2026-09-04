# Compatibility testing

Compatibility claims follow the generated registry in
`portmaster/minecraftbedrock/COMPATIBILITY.md`: **Validated**, **Best effort**,
or **Unsupported**. A successful smoke test does not become Validated until the
complete physical acceptance matrix has passed.

## Per-CFW conformance

`docs/CFW-CONTRACTS.md` states what the port must do on each firmware, with
every clause marked **measured** (observed on a reference device, dated) or
**assumed**. `tests/test_cfw_contracts.py` asserts the script-level clauses and
`tests/test_platform.sh` asserts the capability clauses against fixtures built
from captured device output rather than from plausible-looking guesses.

Reference devices: Anbernic RG34XX-SP on Knulli 20260511 and Anbernic RG DS on
ROCKNIX 20260710 nightly, both captured 2026-08-23; and the same RG34XX-SP on
muOS 2601.0 JACARANDA, captured 2026-08-24 and played end to end on 2026-08-25.
**The ArkOS family — ArkOS, dArkOS, DarkOS RE — has no reference device and
never has.** Its contract is derived from the code and from the log in issue #1,
so it is the one most likely to be wrong, and it is **out of scope for v2.0.0**:
the code paths ship, the support claim does not.

The muOS card failed on 2026-08-25 and is out of the device, so its rows below
record what was measured while it was reachable and cannot be re-run before
release.

### RG34XX-SP missing runtime recovery, 2026-09-04

The Ports entry failed before its normal logs were opened. A traced launch
found all eight top-level payload shell scripts missing from
`/userdata/roms/ports/minecraftbedrock/`. Payload discovery consequently chose
an older `2.0.0-rc.8` installation at `/userdata/ports/minecraftbedrock`, which
then failed with `Missing message helpers.` The cause of the missing files
was not established.

Restored only those missing scripts from the workspace, with LF endings and
executable permissions. Existing code, versions and worlds were retained.
The unchanged top-level entry then displayed its LOVE launcher menu and started
`1.21.51.01-972105101-arm64` at 720x480 on Mali-G31. The startup watchdog
reported its first frame after 23 seconds; a framebuffer capture confirmed
the Minecraft main menu. This was an SSH invocation of the Ports entry, not
an automated controller selection through EmulationStation or an in-world test.

Backed up `gamelist.xml` and marked 11 internal/missing legacy Bedrock entries
hidden while EmulationStation was stopped. The main `Minecraft Bedrock.sh`
entry remains visible. Diagnostic logs and screenshots are local-only under
`build/diagnostics/launch-20260904/`; the pre-repair logs are also saved in the
device's `minecraftbedrock/backups/launch-20260904/` directory.

### Handheld UI prototype, 2026-09-04

Installed the opt-in `packs/handheld-ui` prototype on RG34XX-SP/Knulli with
the fingerprinted `1.21.51.01-972105101-arm64` build. Tests used native 720x480,
density 1 and launcher UI zoom Off. The manager activates only this exact
version, ABI and native-library SHA-256. New profiles default to Off.

Observed on the device:

- Main menu labels and buttons are larger and fit their bounds, including
  Marketplace. Pause menu rows and labels also fit at 1.5x their stock size.
- The HUD hotbar grew from about 182 to 274 pixels wide. A block icon and a
  five-item stack count render inside it, with clearance above the panel edge.
- Creative inventory selection has a visible yellow outline. Inventory slot
  dimensions remain unchanged; selecting items and closing the screen worked.
- Three simultaneous native heart renderers at nominal sizes `[1,1]`,
  `[1.5,1.5]` and `[16,16]` produced identically sized hearts. That diagnostic
  overlay was removed. Health and hunger remain at their original size.
- World loading, the enlarged pause screen, settings and the native death
  screen were exercised in `Handheld UI Test (copy)`, a disposable copy of an
  existing world. Only the copy was renamed and switched to Creative/cheats.

ES-DE did appear behind the game during overlapping manual diagnostic
restarts: an older launcher's exit cleanup restored it after the newer launch
had begun. After waiting for the previous wrapper to exit completely, the
normal Ports entry stopped ES-DE; repeated process checks during the final
launch and world load found no ES-DE process. This is not a general concurrency
fix for overlapping launchers.

All 41 override paths resolve against this build's vanilla UI definitions.
The seven activation tests pass, covering default Off, preservation of other
packs, On/Off, version/ABI/library gating, and malformed-state/collision handling.
Launcher early-exit execution tests, portability contracts and release safety
checks also pass. Changes to the activation file are backed up; the original
run script is saved in the device's `backups/handheld-ui-20260904/` directory.

Remaining checks include damaged tools/durability, armour/air/XP, container
and trading screens, other languages, extended controller navigation, and
physical version switching. Effects optimization is not part of this pack;
no FPS improvement is claimed. Local-only screenshots and the renderer probe
are under `build/diagnostics/handheld-ui-20260904/`.

### Handheld UI integer scaling pass, 2026-09-04

The first prototype scaled the menus and hotbar by 1.5 and left the inventory
alone. On the device that read as blurry text and a hotbar that was still too
small. Both causes are the same: the UI font is a bitmap font and item art is
16x16, so fractional factors resample. Every override was rebuilt from this
build's own stock value times an integer, which also restores vanilla
proportion. Each figure below was confirmed on the RG34XX-SP at native 720x480,
density 1, UI zoom Off, by the maintainer and by framebuffer capture.

- Pocket inventory at 2x: generated by `scripts/build_handheld_inventory.py`
  from the version's own `vanilla/ui`, doubling pixel lengths while keeping
  percentages. Cells, tabs, search bar, armour panel and labels all fit.
- Main menu at 2x (300-wide panel, 64-high rows) and pause menu at 2x
  (56-high rows), both with `$button_font_scale_factor` 2. The stock default is
  1.0; the earlier 1.5 was the blurry-text cause.
- Selected-item name at 2x via `common.item_text_label`, with the
  `common.item_panel_image` border padding doubled so the box tracks the text.
- Hotbar at 3x: 60x66 slots, 48x48 icons, 72x72 selection, count font 3.
  Measured 546x66 on screen, from 364x44 at 2x and 274x33 at 1.5x. 2x was
  judged still too small, and 3x is the next factor that keeps a 16x16 icon
  sharp. `$xp_control_offset` -39 was derived from the measured 2x capture
  rather than guessed, and lands the panel clear of the bottom edge.

The native status renderers were closed out as unfixable from a resource pack.
Beyond the earlier `[1,1]`/`[1.5,1.5]`/`[16,16]` size probe, `heart_renderer`,
`hunger_renderer`, `armor_renderer` and `bubbles_renderer` are all
`"type": "custom"` carrying only visibility bindings, and no `#health`,
`#hunger`, `#absorption`, `#armor_value` or air-supply binding name occurs
anywhere in the version's `vanilla/ui` tree, so equivalent image controls cannot
be built either. Their corner placement is stock `not_centered_gui_elements`
(`top_left [2,2]` for hearts and armour, `top_right [-2,2]` for hunger and
bubbles), not something this pack moved. Launcher UI zoom remains the only
shipping setting that enlarges them; the client viewport override in
[UI-SCALING.md](docs/UI-SCALING.md) remains the unimplemented proper fix.

Also fixed here: `fbgrab` writes alpha 0, so every capture in this directory
renders as a blank white page in ordinary viewers despite holding real content.
The local `device_ui.py` helper now flattens to RGB. Still unverified for this
pass: durability bars, armour/air/XP rows, container and trading screens, other
languages and version switching.

### UI viewport experiment, phase 1, 2026-09-04

Deployed the CI-built patched client (`clients (aarch64, standard)`, all three
client targets green) to RG34XX-SP/Knulli, keeping the previous binary on-device
as `bin/mcpelauncher-client.before-uiscale-20260904`. The patch is inert unless
`MCPE_UI_LAYOUT_SCALE` is set, and the launcher forwards that variable only when
it is set, so a normal launch is unchanged.

Launched `1.21.51.01-972105101-arm64` with `MCPE_UI_LAYOUT_SCALE=1.5` and
`MCPE_MENU=0`, reaching `first-frame`. The client logged
`eglQuerySurface EGL_WIDTH -> 480 (real 720)` and `EGL_HEIGHT -> 320 (real 480)`
while `getScreenWidth` still answered 720.

- The engine laid out and drew its entire frame at the reported size: the
  rendered region measured **480x321** of the 720x480 panel, the rest untouched.
  Rendering is deliberately not corrected in this phase, so this is the expected
  artifact rather than a fault.
- The heart row measured **79x7 px at x=3 in both modes**, so the native status
  renderers draw in surface units. They are 11.0% of a 720-wide surface and
  16.5% of a 480-wide one, which is what makes phase 2 able to enlarge health
  and hunger at all -- no resource pack can.
- The handheld-ui 3x hotbar (546 units) does not fit a 480-wide surface and its
  ninth slot was clipped. Pack factors compose with the surface scale and must
  be reduced when one is in use.

Not covered: pointer input mapping, `glGetIntegerv(GL_VIEWPORT)` readback, Ore
UI behaviour, and anything at a scale other than 1.5. The device was returned to
a clean state afterwards, with ES-DE running and no port processes left.
Local-only captures are under `build/diagnostics/handheld-ui-20260904/`.

### Handheld UI on the Classic UI profile, 2026-09-04

Found by the maintainer, not by this testing: switching **Settings -> Video ->
UI Profile** from Pocket to Classic made health and hunger render behind the
hotbar. Every earlier session tested only Pocket, and the pack was described as
working without that qualification.

The two profiles use different HUD layouts. Pocket draws health from
`not_centered_gui_elements`, anchored into the screen corners. Classic uses
`centered_gui_elements_at_bottom_middle`, a 180x50 panel anchored
`bottom_middle` whose `heart_rend` sits at `[-1,-40]` -- directly above the
hotbar, and independent of `$xp_control_offset`, so it does not move when the
hotbar grows. Stock, the hotbar is 22 tall and ends around y 445, leaving the
row at y 440 clear. At the pack's 3x the hotbar is 66 tall and spans roughly
y 403-469, swallowing it.

Fixed by scaling that panel and its offsets by the same factor as the hotbar:
`[180,50]` to `[540,150]`, hearts and armour `[-1,-40]` to `[-3,-120]`, hunger
`[180,-40]` to `[540,-120]`, bubbles and horse hearts likewise. The stock
180-unit panel matches the stock 182-unit hotbar, so scaling both together keeps
the vanilla relationship rather than inventing a new one.

Verified on RG34XX-SP/Knulli with `gfx_ui_profile:0` and the pack active:

- health row at y 360-366, hotbar top edge at y 387 -- **21 px clear**, no
  overlap.
- hearts start at x 88 against the hotbar's left edge at x 87; hunger ends at
  x 625 against its right edge at x 633.

Not covered: `centered_gui_elements_at_bottom_middle_touch` gets the same
transformation but no touch device was available to test it.

**The Classic inventory cannot be scaled from this pack's namespace at all.**
Worked through its containers individually rather than by blanket factor, and
the obstacle turned out to be structural. The screen is
`crafting.recipe_inventory_screen_content`, whose `content_stack_panel` is a
horizontal stack sized `[326, 166]` -- the number that matches the ~325 px the
stock screen measures on device. Enlarging that panel to `[652, 332]` was tested
in isolation: the container grew and `recipe_book`, sized `["fill", "100%"]`,
filled it, while `player_inventory` stayed stock-sized and ended up marooned
against the right edge.

`player_inventory` has no size of its own. It is a `common.root_panel` whose
geometry comes from `common.common_panel`,
`common.inventory_panel_bottom_half` and `common.hotbar_grid_template`; only its
`$top_half_variant` (`crafting.survival_panel_top_half`) is in the crafting
namespace. A crafting-namespace pack file therefore reaches part of that panel
and not the rest, which is precisely the partial scaling seen every time. It is
namespace ownership, not tuning, and no amount of per-container adjustment
inside `inventory_screen.json` can fix it.

Scaling it properly means overriding `common` prototypes -- `container_item`,
`cell_image`, `common_panel`, `inventory_panel_bottom_half`,
`hotbar_grid_template`. Those are shared by every container screen in the game
(chest, furnace, anvil, beacon, brewing, cartography, enchanting, grindstone,
all of which extend `common.inventory_screen_common`) and by the Pocket
inventory this pack already scales explicitly, so it also risks double-scaling
the path that currently works. That is a much larger and riskier change than the
Classic HUD fix, and it is not attempted here.

**The earlier blanket attempt, for the record.**
The generator emits overrides only for the crafting prototypes Pocket
references, so Classic gets a partial scale. Widening it to the whole `crafting`
namespace (22 overrides to 96) and testing on device produced a worse screen
than stock: the left panel grew to 465 px while the right reached only 220 and
the two overlapped around x 490. The cause is the generator's own rule --
double pixel lengths, leave percentages alone -- which holds the Pocket layout
together because Pocket sizes in pixels, and pulls the Classic layout apart
because Classic mixes both. A blanket factor is the wrong instrument here; the
Classic screen needs its containers considered individually, which was not
attempted.

One thing that is *not* a defect, checked against a pack-off capture of the same
screen: the empty grey Equipment panel appears identically with the pack
disabled. It is stock behaviour on this build, not something the overrides
break.

The generator and `inventory_screen.json` are back at the tested 22-override
version, verified by checksum on the device. Classic therefore keeps the stock
inventory and the fixed HUD.

### UI viewport experiment, phase 2, 2026-09-04

Rendering correction on top of phase 1, tested on RG34XX-SP/Knulli with
CI-built clients against `1.21.51.01-972105101-arm64` at
`MCPE_UI_LAYOUT_SCALE=1.5`.

The first phase 2 build did not run. It aborted at about seven seconds with
`stack corruption has been detected` from `shim::assert_impl`, both with the
variable set and with it unset -- so with no override installed and none of the
new code executing. Isolated against the same device state within minutes: the
stock client reached `first-frame`, the phase 1 client reached `first-frame` at
scale 1.5 with its UIScale lines, and the phase 2 client aborted either way.
The cause was one `thread_local bool` added to `fake_egl.cpp`; removing it fixed
it. See [UI-SCALING.md](docs/UI-SCALING.md).

With that removed, measured:

- Stock UI, pack disabled: the frame filled the whole **720x480** panel instead
  of a 480x321 corner. The start-screen Play button went from 146 px to
  **218 px** (1.49x) -- the figure the scaling matrix in `UI-SCALING.md` records
  as unmoved by every other lever tested.
- **Heart row 79x7 px to 119x10 px** (1.51x). The native status renderers cannot
  be reached from a resource pack, so this is the only measured way to enlarge
  health and hunger.
- Handheld-ui pack at 2x with the 1.5 surface scale: launched clean, hotbar
  measured 537 px against 546 predicted, no clipping. That is the same physical
  hotbar size the 3x pack gives at native resolution, with everything else 1.5x
  larger beside it.

Not covered, and not safe to treat as shipping-ready: pointer input is still
unconverted (no effect on this gamepad-driven handheld, wrong on a touch
device); Ore UI screens are laid out in the same scaled surface and will grow,
which is the opposite of what those already-tight screens need, and were not
examined; the longest run was a couple of minutes, with no play session; and
the rendering half is compiled out on armhf by design.

The device was returned to its stock client and the 3x pack afterwards, both
verified by checksum. Local-only captures are under
`build/diagnostics/handheld-ui-20260904/`.

### Unrestricted scheduler regression test, 2026-08-27

The H700 anti-stutter profile was removed after its original purpose was traced
to RenderDragon. The code-only `lib/platform.sh` change was deployed to both
reference devices, preserving the installed game data and versions. The old
files remain recoverable on-device as
`lib/platform.sh.before-unrestricted-cpu-20260827` and
`run_bedrock.sh.before-unrestricted-cpu-20260827` in each edition's directory.

Both no-RenderDragon editions then completed bounded real-client launches:
1.21.51.01 on RG34XX-SP/Knulli and 1.16.221.01 on RG DS/ROCKNIX. ES-DE was
fully stopped before Bedrock on both systems; ROCKNIX's Sway compositor stayed
active because the game needs it. During the launches:

- The live client environments contained none of `MCPE_PIN_RENDER_CORE`,
  `MCPE_PIN_MAIN_CORE`, `MCPE_PIN_OTHER_CORES`, or `MCPE_FAKE_NPROC`.
- All 32 Knulli client threads and all 69 ROCKNIX client threads reported
  `Cpus_allowed_list: 0-3`.
- Both launch-stage breadcrumbs reached `first-frame`. The final traces held
  1,377 measured frame intervals on Knulli and 2,548 on ROCKNIX.
- The forced timeouts were classified as late failures and left the failsafe at
  rung 0. No client, nested Weston, or RGDS companion process remained, and
  ES-DE was restored on both devices (with Sway still running on ROCKNIX).

This proves the scheduler change reaches the real game and that launch/cleanup
remain sound.

The maintainer then launched 1.16.221.01 normally on both devices and joined
the same LAN world. The transparent hole after a block break was gone, and
chunk streaming appeared better, but an opaque black rectangle briefly covered
the break. An old June hypothesis blamed the vanilla
`minecraft:block_destruct` terrain-atlas billboard. Its first controlled test
on Knulli disproved that diagnosis: setting the emitter count to zero removed
the intended block debris animation while the black rectangle remained. The
workaround has therefore been removed and the original JSON restored. The
remaining investigation is the damage-overlay/chunk-replacement render path.

The same audit found two RenderDragon-era defaults still active on arm64:
whole-asset prewarming and fixed glibc trim/mmap thresholds. Neither had
evidence on 1.16. The prewarm is now opt-in, and the allocator is back on
glibc's adaptive defaults. Async texture loading, its stock dequeue value, and
the multithreaded renderer remain enabled; the latter is required for static
chunk draws on EGLUT/Crusty/libmali.

The live process trees also disproved the launcher's frontend assumption.
Knulli had both `emulationstation-standalone`/`emulationstation` and Bedrock in
the same inherited session for more than four hours; ROCKNIX likewise retained
ES-DE beside Bedrock while Sway hosted the game. Knulli's direct stop passed.
The first analogous ROCKNIX attempt failed: ES is the main child of
`essway.service`, so killing it made systemd terminate the port in the same
cgroup and restart ES. The RGDS entry now moves the real launcher into a
transient systemd scope before it stops `essway.service`; Sway remains in its
own service. A harmless on-device nested-scope test confirmed the child moves
from its parent service cgroup into `/system.slice/<name>.scope`. The first
deployed wrapper still exited before the launcher because ROCKNIX systemd 255
rejects `--wait` with `--scope`; scope mode is already foreground, so the
incompatible flag was removed. Full launch acceptance is pending.

### Reference capture, 2026-08-23

Read-only capture from both devices; nothing was installed or modified.

- **RG34XX-SP / Knulli**: identity resolved to `knulli` (explicit). During a
  real launch `CFW_NAME=knulli` (derived by `device_info.txt`, not written in
  `control.txt`), and the os-release fallback independently reaches the same
  answer from `OS_NAME="knulli"` even though that file otherwise calls itself
  `Batocera.linux`. Capability probe: profile `h700` (matched on `sun50iw9p1`; the
  device never reports "h700"), backend `mali`, no `/dev/dri` at all, panel
  720x480 taken from `fbset` rather than the 720x960 `virtual_size`, audio
  `pulse` via `/var/run/pulse/native`. Both loaders present but the 32-bit
  client correctly unusable for lack of `/dev/dri`. `readelf` is absent.
  Shared data already on the hidden `.minecraftbedrock-data` root, so the
  corrected Knulli detection is a no-op on this device.
- **RG DS / ROCKNIX**: identity `rocknix` (explicit); `CFW_NAME=ROCKNIX` and
  `OS_NAME="ROCKNIX"` agree. Profile `rgds`, `MCPE_IS_RGDS=1`,
  backend `wayland` under sway, two connected DSI panels at 640x480, audio
  `pulse` resolved at `/run/0-runtime-dir/pulse/native` — reachable only
  through the `/run/*-runtime-dir/pulse/native` candidate. `nproc` is absent,
  confirming the busybox fallback is required. Root filesystem is a read-only
  loop mount at 100% use. Shared data on the visible root, as it should be.
- The launch-stage breadcrumb round-tripped on both devices: a run that ended
  at `client-exec` was reported as the previous stage on the next start.

### Live launch, RG34XX-SP / Knulli, 2026-08-23

The Phase 0-3 payload was deployed to the reference RG34XX-SP (code only; the
`apk`/`versions`/`profiles`/`backups` symlinks into the 3 GB shared data root
and `config/` were never touched, and the previous code was archived on-device
as `minecraftbedrock-code-before-phase03-*.tgz`). Bedrock 1.16.221.01 arm64 was
launched twice over SSH with the menu bypassed and a forced timeout.

Passed:

- Boot report complete and correct: `cfw=knulli (explicit)`, `profile=h700`,
  `backend=mali`, `panel=720x480`, `audio=pulse`, `abi=arm64 (installed 64=1
  32=0; usable 64=1 32=0)`, Weston runtime resolved.
- Both in-client guards applied, confirming the Phase 2 registry correction:
  `[Compat] Patched isEduMode null-deref (1.16.x)` and `[Compat] Patched 1.16
  startup HTTP-resolve crash`. The launcher therefore correctly left the game
  online (`network=mode=auto offline=0 guarded=1`) instead of taking LAN away.
- The game rendered: 5601 frames in ~120 s (~46 fps) on the first run;
  `getScreenWidth -> 720`, `getScreenHeight -> 480`.
- Startup watchdog armed, saw the first frame after 6-11 s, disarmed itself,
  and wrote no hang report.
- Failsafe ladder stayed at rung 0. Both timed exits were classified
  `late_failure` with the rung unchanged, which is the intended handling of a
  non-zero exit after the startup window.
- Clean shutdown both times: no leftover client, no leftover Weston, ES still
  running.
- Audio triage selected the Pulse path via `/var/run/pulse/native`.

Found and fixed by this launch: `lib/common.sh` reset `MCPE_STAGE_FILE` on
every source, so the breadcrumb was silently disarmed for every child script.
The first run recorded `version` and then jumped to `done`, losing exactly the
`client-exec`/`window`/`first-frame` evidence a hang report needs. After the
fix the second run recorded `client-exec` -> `first-frame` -> `done`. A
regression test now re-sources `common.sh` in a subshell and asserts a child
can still advance the breadcrumb.

The signal 11 during forced teardown is the already-documented behaviour of the
1.16 engine when its compositor is removed under the timed harness.

### Menu-driven launch and clean exit, both devices, 2026-08-23

Reported by the maintainer and corroborated from each device's failsafe ledger:
launching and exiting from the on-device menu with real controller input works
on both. The ledgers recorded, with no forced timeout involved:

| Device | Rung | Outcome | Session | Exit |
|---|---|---|---|---|
| RG34XX-SP / Knulli | 0 | `success` | 53 s | 0 |
| RG DS / ROCKNIX | 0 | `success` | 1261 s (21 min) | 0 |

This closes the two gaps left by the SSH launches and exercises what those
could not:

- The LOVE menu rendered and accepted controller input with the two entries
  added in this work (`Network / LAN`, `Safe mode`) present in its schema.
- A real in-game exit produced status 0, which the ladder classified `success`
  at rung 0 — the first non-timeout exits of this checkpoint.
- The 21-minute ROCKNIX session is evidence the startup watchdog's stall
  detection does not false-fire during ordinary play: it disarms at the first
  frame and wrote no hang report.
- Both devices ended at rung 0, `floor 0`, `streak 1`, with no escalation.

### Live launch, RG DS / ROCKNIX, 2026-08-23

The shared Phase 0-3 code was deployed to the reference RGDS, preserving
everything that makes it the RGDS edition: its own telemetry client and context
bridge in `bin/`, `edition.json` (`id=minecraftbedrock.rgds`), the `rgds/` tree
(bottomd, bedrockmap, session and OSK scripts), and the deliberate absence of
`bin32`, `lib32`, `downloader` and `run_bedrock32.sh`. Previous code archived
on-device as `minecraftbedrock-rgds-code-before-phase03-*.tgz`.

Every ROCKNIX contract clause held:

- `cfw=rocknix (explicit, CFW_NAME=ROCKNIX, os=ROCKNIX)`, `profile=rgds`,
  `edition=minecraftbedrock.rgds`.
- `backend=wayland compositor=sway` — the KMSDRM path was never selected, so
  sway kept DRM master.
- Session adoption over SSH worked: `SWAYSOCK=/var/run/0-runtime-dir/sway-ipc.0.sock`.
- Audio resolved at `/var/run/0-runtime-dir/pulse/native`, reached through the
  `/run/*-runtime-dir/pulse/native` candidate — the only one matching this
  firmware.
- Panel `640x480` from `card0-DSI-1`; the dual-screen companion started
  (`top=DSI-2 bottom=DSI-1 touches=2`).
- Stage breadcrumb measured on-device: `payload` -> `migrate` -> `probe` ->
  `version` -> `abi` -> ... -> `done`. Startup watchdog saw the first frame
  after 8 s and disarmed. 1630-1732 frames per ~45-60 s run.
- Cleanup after forced timeout: no client, no bottomd, no Weston, no telemetry
  shared memory, sway still running with both DSI outputs active, ES running.
- One run exited cleanly with status 0 and was recorded as `success`.

Found and fixed by this launch: the failsafe ladder counted a breadcrumb
stopping at `first-frame` as an inferred *startup* failure. Reaching the first
frame means startup worked, so an interrupted session was escalating a device
that demonstrably runs the game — the RGDS was pushed to rung 1 this way.
`first-frame` is now classified as `interrupted_after_start` and leaves the rung
alone; stages before it still escalate. Both devices had their ladder state
reset to rung 0 afterwards.

## Current 2.0 testing evidence

- Portability checkpoint (2026-08-14): all host-side tests, deterministic
  release assembly, installer bundle/rollback fixtures, Knulli/muOS/ROCKNIX/
  dArkOS host fixtures, and exact upstream patch-apply checks passed. The live
  RG34XXSP/Knulli device selected arm64, discovered its existing 1.16.221.01
  install with hidden transaction state present, selected an installed UTF-8
  locale, and produced the expanded redacted support bundle without launching
  Minecraft or changing frontend state. The arm64 native client was then built
  twice from the pinned container/source inputs with matching SHA-256
  `ced5e57e1a4d5574998b80edaf80e81d3f855ff5eea639cbf86b73f835bff966`
  and deployed with its predecessor retained. A user-driven menu/game launch
  remains the final physical acceptance action for this checkpoint.

- RG34XX-SP, Knulli Scarab, arm64/H700/Mali: the original no-RenderDragon
  Bedrock 1.21.51.01 official split set (native-library SHA-256
  `45382be72491ec2cbe5dd4d1262989ad894b8fc611e5cbc16141d04171510927`)
  installed transactionally; launcher, JNI, Mali-G31 GLES 3.2, 720x480 UI,
  controller discovery, world load, gameplay, and native PulseAudio output
  passed. Clean exit completed two seconds after the stop callback with exit
  code 0, frontend restoration, and no leftover launcher or Weston process;
  the shutdown watchdog remained an unused fallback.
- RGDS, ROCKNIX 20260710, arm64/RK3566/Sway: the same fingerprinted original
  no-RenderDragon Bedrock 1.21.51.01 loaded an
  existing world and connected the player; dual outputs, live telemetry,
  companion UI, local-world terrain minimap, SELECT swap events, audio initialization,
  forced-exit cleanup, shared-memory removal, native Sway placement restoration,
  and frontend state passed. Raw map-panel touch routing passed on both physical
  panels across repeated SELECT swaps, including center and zoom controls. The
  wider incremental map window rendered terrain passes in zero to one second.
- RGDS LAN regression: joining an RG34XX-SP-hosted world exposed that the
  Bedrock client does not keep the host's LevelDB chunks locally. The first
  candidate observed IPv4 only, while the physical session used IPv6, so it
  correctly retained live coordinates but failed to clear the old map. The
  replacement classifies IPv4/IPv6 direct Bedrock peers, invalidates prior
  terrain/waypoints, pauses the LevelDB worker, and preserves live telemetry
  behind `REMOTE WORLD / MAP UNAVAILABLE`. Host-side transition coverage and
  clean pinned builds pass; physical confirmation after relaunch is pending.
- RGDS local minimap responsiveness: the worker now identifies the game's open
  world through `/proc/<pid>/fd`, avoiding the old wait for movement to update
  LevelDB mtime. The default radius is 12 chunks (625 lookups instead of 2,401),
  with the central 10-chunk area flushed before an optional outer ring.
- The replacement on-device companion is the full `bottomd`; it opens
  the dynamically discovered physical map-panel evdev device initially and
  after every SELECT swap. Its HUD/Chat/Items/Input/Settings shell, snapshot
  parser, independent Chat/Items renderer, command ABI, runtime resource index,
  stale fallback, container auto-switch/restore, and blank-screen guard pass
  the deterministic host suite. The full companion and bridge-enabled launcher
  still require a physical RGDS confirmation together; bottom-panel confirmation
  of this revision is pending.
- Bedrock 1.16.221.01 arm64: on RG34XX-SP the isolated legacy profile, guarded
  EduMode and HTTP-resolver patches, Mali-G31 GLES 3.2 rendering, 720x480 size,
  and an active PipeWire sink passed. On RGDS the game, live telemetry stream,
  companion UI, two dynamically discovered touchscreens, and terrain worker
  started. Forced-timeout cleanup on both devices left no game/companion
  process; RG34 restored ES, while RGDS removed telemetry shared memory and
  restored both Sway outputs and input state. The old 1.16 engine reports
  signal 11 when its compositor is deliberately removed by the timed harness;
  the supervisor contains it and completes cleanup.
- Bedrock 1.20.62.02 arm64 (retained compatibility build, not a 2.0 gate): the
  metadata guard and expected instruction signature both matched on RG34XX-SP,
  the optional periodic auto-compaction patch applied, and timed cleanup
  restored ES without leftover game or Weston processes.

Host FMOD remains optional; the launcher fallback is used when no legally
obtained host FMOD library is installed.

These combinations remain **Best effort** until controller/OSK/text entry,
backup/restore, sleep/resume where supported, clean in-game exit/relaunch, and
the remaining Bedrock/device anchors are manually completed.

## Per-CFW acceptance checklist

A firmware stays **Best effort** until every row below passes on a physical
device of that family. Copy this table into a device report and fill it in;
`selftest.sh` answers the first three rows on its own.

| # | Check | What counts as a pass |
|---|---|---|
| 1 | Self test | `selftest.sh` reports 0 failures |
| 2 | Identity | the boot report names the right firmware, profile and graphics backend |
| 3 | Panel | the reported panel size matches the physical screen |
| 4 | Install | an APK installs from the menu, transactionally, with no partial state left |
| 5 | Launch | the game starts from the on-device menu with controller input |
| 6 | First frame | `logs/stage.txt` reaches `first-frame`, or the game visibly renders |
| 7 | Audio | sound is audible in game, not merely a backend that opened |
| 8 | Controls | every face button, shoulder, d-pad and stick does the right thing in game |
| 9 | Text entry | a world can be named and text typed where the game asks for it |
| 10 | World load | a world creates, loads and saves |
| 11 | LAN | a second device joins, or is deliberately reported as not applicable |
| 12 | Clean exit | quitting from inside the game returns to the frontend with exit status 0 |
| 13 | Relaunch | starting again immediately afterwards works |
| 14 | Frontend restored | the frontend is usable, with no leftover client, Weston or companion process |
| 15 | Ladder unchanged | `logs/failsafe-ledger.tsv` records `success` at rung 0, with no escalation |

Current state:

| # | Knulli (RG34XX-SP) | ROCKNIX (RG DS) | muOS (RG34XX-SP) | ArkOS family |
|---|---|---|---|---|
| 1 Self test | pass | pass | pass, 2026-08-25 | — |
| 2 Identity | pass | pass | pass, 2026-08-24 | — |
| 3 Panel | pass | pass | pass, 2026-08-24 | — |
| 4 Install | pass (earlier checkpoints) | pass (earlier checkpoints) | pass, 2026-08-25 | — |
| 5 Launch from menu | pass | pass | pass, 2026-08-25 | — |
| 6 First frame | pass | pass | pass, 2026-08-25 | — |
| 7 Audio | pass (earlier checkpoints) | pass (earlier checkpoints) | pass, 2026-08-25, heard (a v1.x no-audio report was fixed in v1.4.1) | open, see issue #1 |
| 8 Controls | not re-verified | not re-verified | pass, 2026-08-25 | open, see issue #1 |
| 9 Text entry | not verified | not verified | not verified | — |
| 10 World load | pass (earlier checkpoints) | pass (earlier checkpoints) | pass, 2026-08-25 | — |
| 11 LAN | pass (earlier checkpoints) | known limitation, see below | not verified; a v1.x report described the game exiting with Wi-Fi on (FS-1 in docs/FAILSAFES.md) | — |
| 12 Clean exit | pass | pass | pass, 2026-08-25 | — |
| 13 Relaunch | not verified | not verified | not verified | — |
| 14 Frontend restored | pass | pass | pass, 2026-08-25 | — |
| 15 Ladder unchanged | pass | pass | pass, 2026-08-25 | — |

A dash means no reference device and no report covering that row.

The muOS column comes from one session on 2026-08-25 on an RG34XX-SP running
2601.0 JACARANDA: Google sign-in on the device, the 1.16.221.01 arm64 split set
downloaded, installed and played for 488 s with sound and controls working,
`exit_status=0 (success)`, `failsafe=rung=0 (tuned) floor=0`, and the frontend
back on its own menu afterwards. Rows 9, 11 and 13 were never exercised, and the
card failed the same day, so they stay open rather than being inferred from the
rest. `docs/CFW-CONTRACTS.md` and `docs/FAILSAFES.md` carry the full capture.

The ArkOS column is empty because there has never been a device. v2.0.0 does not
claim the family; its code paths ship unverified and a single **Self test**
paste from an ArkOS-family device is still the one input that would change that.

## Release-gating tracks

- arm64 no-RenderDragon blocking track: **1.16.221.01** is the recommended
  everyday/default version because its UI scales cleanly on these handheld
  displays. The exact fingerprinted original **1.21.51.01** is the newest
  tested no-RenderDragon version, but is not the default because its UI scaling
  is less usable.
- arm64 RenderDragon/unknown track: 1.17.41.01, 1.20.15.01, 1.20.51.01,
  1.20.62.02, and 1.21.50.28 are optional non-blocking compatibility smokes.
  Their severe stutter on these devices makes them inappropriate release gates
  or recommendations.
- armhf: 1.16.40.02 and 1.16.221.01, including R36S exact-mode validation.
- negative: 1.26.32.2 PairIP/new-ABI rejection without partial installation.

The 1.21.51.01 version name is not sufficient identification: a later reupload
enabled RenderDragon while retaining that version. Only the exact registered
native-library fingerprint receives the `newest tested no-RenderDragon` label.
Other 1.21.51.01 libraries receive a visible warning and are not recommended.
Synthetic full/split and PairIP rejection tests do not replace the negative
physical package test.

## Required report fields

- device model and firmware/OS version
- Bedrock version, version code, full/split form, and ABI (never the APK)
- resolved capability profile and backend
- extraction, graphics/resolution, audio, controls, touch, OSK, LAN/world load
- clean exit, immediate relaunch, and restoration state
- relevant redacted support bundle

Never upload APKs, extracted game libraries/assets, worlds, account data,
`versions/`, `profiles/`, or `libminecraftpe.so`.
