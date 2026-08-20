# Compatibility testing

Compatibility claims follow the generated registry in
`portmaster/minecraftbedrock/COMPATIBILITY.md`: **Validated**, **Best effort**,
or **Unsupported**. A successful smoke test does not become Validated until the
complete physical acceptance matrix has passed.

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
