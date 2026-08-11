# Telemetry module (game-process side)

Publishes live camera position/heading, container/death events, and
frame metrics to `/dev/shm/mcpe_telemetry` for `bottomd` and
`telemetry_dump`. Design + data-source rationale:
`../analysis/SYMBOL_FINDINGS.md`. Shm layout: `mcpe_telemetry_abi.h`
(the ONE file readers include; bump `MCPE_TELEMETRY_ABI_VERSION` on any
layout change).

## Files

| File | Role | Where it ends up |
|---|---|---|
| `mcpe_telemetry_abi.h` | shm ABI + header-only reader | client tree AND bottomd |
| `telemetry_writer.{h,c}` | seqlock publisher | client tree |
| `fmod_listener_hook.c` | FMOD listener interposer (the position feed) | client tree |
| `telemetry_dump.c` | debug reader CLI | dev/debug tooling, also on-device |
| `test_feed.c` | fake game for reader/bottomd dev | PC only |
| `Makefile` | standalone build + `make check` smoke test | PC only |
| `rgds_device_verify.sh` | RG DS staged deploy + menu telemetry smoke test | WSL/dev only |

Status: built clean and `make check` PASSED on WSL (gcc, 2026-07-10).
These sources are plain C11 with no launcher dependencies; they compile
unchanged for aarch64 and armhf.

## Integrating into mcpelauncher-client — APPLIED 2026-07-10

Integration is DONE in the WSL tree and the arm64 client built clean
(`eglut_build/mcpelauncher-client.arm64.telemetry`, telemetry symbols
verified present). Mechanics:
- `apply_client_patch.py` — the (idempotent, rerunnable) patcher that
  performed the integration; `client_integration.diff` — the resulting
  tree diff for review.
- Chosen mechanism: pre-seeded symbol-map override. `loadLibraryOS` now
  keeps pre-seeded entries; `loadFMod(overrides)` forwards them; main.cpp
  seeds the FMOD listener interposer and passes the real host `dlsym`
  pointer to `mcpe_telemetry_set_real_fmod_listener`. Frame metrics feed
  from `FrameMetricsState::record` in fake_egl.cpp (CSV off or on).
- Pristine backups: WSL `/root/bedrockmap/backup_pre_telemetry/`.
- RG DS menu/frame telemetry smoke passed 2026-07-10 via
  `rgds_device_verify.sh`: shm appeared, fps was ~60, and frame count
  advanced. A real in-world RG DS attempt later confirmed `Player connected:
  Steve` and continued frame telemetry, but FMOD position/yaw stayed zero
  with `flags=[]`; investigate the listener hook path on RG DS/1.16.221.01.
  Optional 1.16 event hooks (death/container) remain step 4 below.

## RG DS staged launch caution

When testing under sway, do not launch the staged binary under the filename
`mcpelauncher-client.telemetry`: the Wayland `app_id` follows the executable
name and the PortMaster focus/fullscreen helpers expect `mcpelauncher-client`.
Use a temporary copy/symlink such as `/tmp/mcpelauncher-client`, point
`BIN_OVERRIDE` at that, and explicitly move/focus it to `DSI-2`.

## Original integration guide (reference; steps 1–3 done, 4–5 remain)

The WSL tree is `/root/mcpe/work/source/mcpelauncher` (PRECIOUS —
uncommitted mods, never reset). Steps:

1. Copy `mcpe_telemetry_abi.h`, `telemetry_writer.{h,c}`,
   `fmod_listener_hook.c` into `mcpelauncher-client/src/telemetry/` and
   add them to that target's CMake sources. Keep these byte-identical to
   `bottomscreen/telemetry/` (durable copy) — sync back any change.
2. **Wire the FMOD hook.** Find where the client/linker loads the game's
   `libfmod.so` and how libminecraftpe.so's imports get resolved
   (`mcpelauncher-linker`; libc-shim's wholesale symbol override is the
   in-tree precedent). Two options, either is fine
   (`fmod_listener_hook.c` header comment has details):
   - register `mcpe_telemetry_fmod_listener_hook` under
     `MCPE_TELEMETRY_FMOD_LISTENER_SYM` before the game lib resolves, and
     pass the real `dlsym(fmod_handle, ...)` result to
     `mcpe_telemetry_set_real_fmod_listener()`; or
   - GOT-patch the game lib's entry for that symbol after load.
   MUST-DO either way: set the real pointer, or 3D audio positioning
   silently breaks (hook falls back to recording-only + FMOD_OK).
3. **Wire frame metrics.** At the existing `MCPE_FRAME_METRICS` CSV
   instrumentation site (the client already computes frame/swap times),
   add `mcpe_telemetry_frame(frame_ms, swap_ms);` unconditionally (the
   writer self-gates on `MCPE_TELEMETRY=0`).
4. Optional, 1.16.221.01 only (exported symbols, see SYMBOL_FINDINGS):
   dlsym-hook `VanillaClientGameplayEventListener::onLocalPlayerDeath`
   → `mcpe_telemetry_death(...)`, and Chest/BlockContainer
   ScreenController ctor/dtor → `mcpe_telemetry_container(1/0)`.
   Skip on any version where the symbols are absent.
5. Rebuild via `eglut_build/_container_build_incr.sh` (see
   AGENT_HANDOFF.md §4), deploy to the RG34XX-SP, run any world, and
   check with `telemetry_dump` (cross-compile it or run the aarch64
   build) — position should track movement, yaw should track look
   direction, `age` should stay <100 ms in-game.

## Env knobs

- `MCPE_TELEMETRY=0` — disable writer entirely.
- `MCPE_TELEMETRY_SHM=/name` — override shm name (writer + readers).
