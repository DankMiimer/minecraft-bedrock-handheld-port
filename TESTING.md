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

Reference devices: Anbernic RG34XX-SP on Knulli 20260511, and Anbernic RG DS on
ROCKNIX 20260710 nightly — both captured 2026-08-23. **muOS and dArkOS have no
reference device**, so their contracts are derived from the code and the two
field reports and are the ones most likely to be wrong.

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

| # | Knulli (RG34XX-SP) | ROCKNIX (RG DS) | muOS | dArkOS |
|---|---|---|---|---|
| 1 Self test | pass | pass | — | — |
| 2 Identity | pass | pass | — | — |
| 3 Panel | pass | pass | — | — |
| 4 Install | pass (earlier checkpoints) | pass (earlier checkpoints) | — | — |
| 5 Launch from menu | pass | pass | — | — |
| 6 First frame | pass | pass | — | — |
| 7 Audio | pass (earlier checkpoints) | pass (earlier checkpoints) | reported fixed in v1.4.1 | open, see issue #1 |
| 8 Controls | not re-verified | not re-verified | — | open, see issue #1 |
| 9 Text entry | not verified | not verified | — | — |
| 10 World load | pass (earlier checkpoints) | pass (earlier checkpoints) | — | — |
| 11 LAN | pass (earlier checkpoints) | known limitation, see below | reported broken with Wi-Fi on | — |
| 12 Clean exit | pass | pass | — | — |
| 13 Relaunch | not verified | not verified | — | — |
| 14 Frontend restored | pass | pass | — | — |
| 15 Ladder unchanged | pass | pass | — | — |

A dash means no reference device and no report covering that row. muOS and
dArkOS cannot progress past row 1 without a volunteer running `selftest.sh`,
which is why the issue template now asks for it first.

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
