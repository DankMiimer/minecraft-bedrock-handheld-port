# Failsafes and how to delete them

Every fallback in this port is debt. It exists because some device could not
run the normal path, and it should be removed once that device can. This file
is the record: what each failsafe does, which report justified it, and **the
evidence required to delete it**.

`tests/test_portability_contracts.py` asserts that every rung and knob named in
`minecraftbedrock/lib/failsafe.sh` still has a row here, so a failsafe cannot
quietly become permanent.

## How the ladder behaves

Per (port build, CFW, Bedrock version, ABI preference):

| Rung | Name | What it changes |
|---|---|---|
| 0 | tuned | Nothing. The measured profile; CPU scheduling is left to Bedrock and the kernel. |
| 1 | conservative | No CPU/GPU governor changes, clears opt-in legacy thread pins/faked CPU count, no options.txt rewriting, no asset prewarm, VSync on, 30 fps, offline mode. |
| 2 | minimal | Rung 1, plus X11 video, no Crusty context hand-off, audio off, 20 fps. |
| 3 | diagnostic | Minecraft is not started. A support bundle is collected instead. |

- An **observed** startup failure (the launcher returned non-zero inside the
  120 s startup window) escalates one rung *and* raises the floor, so the
  ladder never drifts back below a rung that is known bad on that device.
- An **inferred** failure (the previous launch never returned; the breadcrumb
  stopped at `abi`, `runtime`, `client-exec` or `window`) escalates one rung but
  does **not** raise the floor, because that signal cannot distinguish a freeze
  from a player pulling the power.
- A breadcrumb stopping at **`first-frame`** is *not* a failure at all: startup
  demonstrably worked, so the session was interrupted during play and the rung
  is left alone. The reference RGDS caught this — an interrupted session was
  logged as an inferred startup failure and pushed a working device to rung 1.
- A **late** failure (non-zero exit after the startup window) changes nothing.
  Crashing after an hour of play is not a startup problem.
- Two consecutive clean launches climb back one rung, never below the floor.
- `safe_mode=0..3` in `config/settings.cfg` (or `MCPE_SAFE_MODE`) pins a rung
  and stops the ladder from choosing. `safe_mode=0` is the way back to normal.
- A new port build gets a fresh rung 0, because the fix may be in the update.

Every rung above 0 is announced on screen and written to
`logs/failsafe-ledger.tsv` with the reason.

## The register

| ID | Failsafe | Why it exists | Delete when |
|---|---|---|---|
| FS-1 | `MCPE_FAKE_NO_NETWORK=1` at rung 1+ | Reddit report (muOS, RG35XX-H, 10 Jul): the game reliably exits before the character menu with Wi-Fi on, and reliably reaches it offline. The in-client guard `patchOldHttpResolveCrash` only fires on arm64 1.16.221.01, so every other build is unprotected. | Three independent reports of a Wi-Fi-up launch succeeding on the affected ABI/version, **or** the resolver guard is generalised beyond the single hardcoded arm64 offset. Until then this is also the fallback that F1 (Phase 2) turns on by default for unguarded legacy builds. |
| FS-2 | Opt-in legacy thread tuning is cleared at rung 1+ (`MCPE_PIN_RENDER_CORE`, `MCPE_PIN_MAIN_CORE`, `MCPE_PIN_OTHER_CORES`, `MCPE_FAKE_NPROC` unset) | The automatic H700 profile was removed on 2026-08-27: its two-CPU worker pool and cores 0-1 confinement delayed chunk generation and chunk-mesh rebuilds on non-RenderDragon builds. The client still accepts these variables for explicit comparison runs, so a conservative launch must clear them. | Rebuild the clients without the legacy affinity/fake-CPU hooks, or teach the ladder to record and restore a user's explicit overrides after the diagnostic launch. |
| FS-3 | No CPU/GPU governor change at rung 1+ (`MCPE_PERFORMANCE_MODE=0`, `MCPE_PERFORMANCE_OPTIONS=0`) | `enable_performance_mode` writes `performance` to every cpufreq policy and GPU devfreq node. On an unknown thermal design that is a plausible cause of a start that never completes. | A thermal/stability pass on each CFW in the matrix. |
| FS-4 | `SDL_DRIVER_OVERRIDE=x11` at rung 2 | `lib/platform.sh` picks `mali`/`wayland`/`x11` from capability probing. When that guess is wrong there is currently no recovery, and `x11` is the path `run_bedrock.sh` documents as the general fallback. | The capability probe is confirmed correct across the four-CFW matrix, or the launch path gains a real in-process renderer retry. |
| FS-5 | `GAMEWINDOW_EGLUT_CRUSTY_CONTEXT=0` at rung 2 | The explicit EGL context hand-off is required on libmali/no-DRM devices and inert elsewhere; switching it off is the documented alternative when the shim misbehaves. | Crusty context hand-off is validated on every device family in the matrix. |
| FS-6 | Audio off at rung 2 (`MCPE_ALSOFT_DRIVERS=null`, `MCPE_SDL_AUDIODRIVER=dummy`) | Issue #1 (dArkOS RE): OpenAL Soft picks PipeWire, whose client config is absent, then RTKit fails. Reddit (muOS Jacaranda): raw ALSA returns "Device or resource busy" because PipeWire holds the device. A failing audio open is a credible cause of a start that never completes, and silence localises it. | **Half discharged.** F3 landed: `lib/audio.sh` now runs on both paths and refuses to offer OpenAL a PipeWire with no client config, which is the dArkOS cause. Delete this rung once that triage is confirmed on a physical dArkOS and muOS device; until then it stays as the backstop for audio faults the triage does not predict. |
| FS-7 | Breadcrumb-inferred escalation | A launch that never returns could only be detected on the *next* launch. | **Mostly discharged.** F2 landed: the startup watchdog terminates a stalled launch, writes `logs/hang-report.txt`, and records `window`/`first-frame`, so the common case now reports itself within the same run. The inference stays for the cases the watchdog cannot see — a client that spins on the CPU forever, and a device that loses power outright. Delete it when a positive in-client progress signal exists that does not depend on opt-in frame metrics. |
| FS-8 | Rung 3 diagnostic stop | Without it, a device that fails at every rung would keep relaunching into the same failure with no artefact to report. | Never for the mechanism itself; it is the ladder's terminal state. Its *reachability* should drop to zero as the rungs above are deleted. |
| FS-9 | Frame rate clamped at rung 1+ (`MCPE_MAX_FPS=30`, `MCPE_VSYNC=1`; 20 fps at rung 2) | A launch that fails to start may be failing under its own frame budget: the tuned profile targets 30 fps with VSync off (50 on 1.16.221.01 and older), which on an unknown GPU is a guess about how much work per frame the device can finish. Clamping removes that variable. | A device reaching first frame at the tuned profile makes this unnecessary for it. Remove the clamp once the arm64 and armhf presets each have a physical acceptance pass, since at that point the frame budget is measured rather than assumed. |
| FS-10 | Optional extras forced off at rung 1+ (`MCPE_PREWARM_GAMEPLAY_ASSETS=0`, `MCPE_DISABLE_AUTO_COMPACTION=0`) | Both are opt-in and already default to off, but a device that cannot start must not also be running an asset prewarm that reads thousands of files off a slow card, or a version-specific binary patch. Pinning them makes the conservative rung mean the same thing regardless of what the user enabled. | Delete when the ladder records the settings it overrode, so a user's opt-in can be restored on the way back down instead of being pinned off. Until then the cost is only that a diagnostic launch ignores two optional features. |
| FS-11 | Painting `/dev/fb0` directly to show a message (`mcpe_msg_framebuffer`) | muOS binds no framebuffer console: `/proc/consoles` lists only `ttyS0` and the sole vtconsole is the dummy driver, so `/dev/tty1` is writable and never reaches the panel. Every launcher message was invisible there, which is what "black screen, then back to the menu" was. The LOVE rung above it covers this whenever PortMaster's runtime is installed; this rung is for when it is not, which is exactly when a player most needs telling. It renders with ImageMagick and the port's own font, so it depends on neither. | Every firmware in the matrix either renders the console or is guaranteed to have the LOVE runtime present. Until then, deleting this puts a player back on a silent black screen with nothing to report. |

## Status

Reviewed 2026-08-27 against the post-v2.0.1 tree. The automatic H700 affinity
profile has been removed; the optional client hooks and the rung-1 safeguard
remain until a client rebuild removes them or the ladder can restore overrides.

A muOS reference device arrived on 2026-08-24 and closed the *capability* half
of the dependency this register was waiting on: identity, graphics backend,
panel geometry, audio stack, ABI and runtime availability. On **2026-08-25 it
closed the behavioural half too.** After its filesystem was repaired and four
faults were fixed on the way through — the PortMaster stub, an invisible
message, the Crusty SDL library, and the sign-in browser's renderer, controller
and second frontend — a player signed in to Google on the device, downloaded
the 1.16.221.01 split set, installed it and played. From `logs/boot-report.txt`
for that session:

    cfw=muos (explicit, CFW_NAME=muOS, os=muOS)
    graphics=backend=mali compositor=none
    audio=backend=pipewire alsa=1 pulse=0 pipewire=1
    failsafe=rung=0 (tuned) floor=0 pinned=0
    bedrock=1.16.221.01 code=971622101 abi=arm64
    exit_status=0 after 488s (success)
    failsafe_next=rung 0 on the next launch

Sound and controls both worked, reported by the player at the device. So the
rows below now separate cleanly into what muOS has answered and what still
needs a firmware nobody here owns.

What the earlier run established is that the ladder was previously unreachable
on muOS for a different reason: the port resolved PortMaster to a stub
directory, found no LOVE runtime, and then reported "no version installed" to
`/dev/tty1` on a firmware that renders no console. The player saw a black
screen. Both are fixed, and the second is why FS-11 exists.

| ID | Status | What is still missing |
|---|---|---|
| FS-1 | Not evidenced | Both reference devices run a build the in-client guard covers, so they launch with `offline=0` and never exercise this fallback. It needs a report from an affected build — armhf 1.16.x, or muOS on a version the guard misses. |
| FS-2 | Default removed; safeguard retained | H700 launches no longer set any affinity or fake-CPU variables. The old opt-in hooks remain in the shipped clients for A/B testing, and rung 1 clears them so a manually tuned launch can still recover. |
| FS-3 | Partly evidenced | Performance mode was active at rung 0 across a 21-minute ROCKNIX session, repeated Knulli launches, and an 8-minute muOS session (`CPU=performance GPU-min=648000000`, exit 0). Three firmwares, all clean — stability evidence, still not a thermal pass. None for dArkOS. |
| FS-4 | Partly evidenced | The capability probe picked `mali` on Knulli, `wayland` on ROCKNIX and `mali` on muOS, all three confirmed correct on hardware — muOS exposes no `/dev/dri` at all, which the previous invented fixture had wrong. Three of four firmwares, but none of the three has exercised the rung 2 override itself. |
| FS-5 | Partly evidenced | The Crusty context hand-off worked at rung 0 on both reference devices, on the libmali and the Sway path. Untested on the ArkOS/KMSDRM family. |
| FS-6 | Half discharged | `lib/audio.sh` runs on both launch paths and refuses PipeWire with no client config, which is the dArkOS cause from issue #1. Knulli and ROCKNIX resolve the Pulse path correctly. muOS resolves the shape it was predicted to have — PipeWire with **no** Pulse socket at `/run/pipewire-0`, `/usr/share/pipewire/client.conf` present, so OpenAL is offered PipeWire — and on 2026-08-25 that path was **heard**: `audio=backend=pipewire alsa=1 pulse=0 pipewire=1`, sound working in a real session. What is still missing is the firmware the rung was written for: a physical dArkOS. |
| FS-7 | Mostly discharged | The watchdog now reports a stall within the same run, and `window`/`first-frame` were recorded on both devices under rc.11. A reached-first-frame breadcrumb no longer counts as a startup failure. What remains is a client that spins forever and a device that loses power, neither of which the watchdog can see. |
| FS-8 | Permanent mechanism | Terminal state of the ladder. Its *reachability* is the thing to drive to zero; it was never reached on either device. |
| FS-9 | Partly evidenced | Both reference devices reached first frame at the tuned profile under rc.11 (11 s and 8 s), so the clamp was never needed there. Removal still needs a physical acceptance pass for the armhf preset, which has no device. |
| FS-10 | Not evidenced | Needs the ladder to record and restore overridden settings; nothing has been built for that yet. Low priority: both knobs default to off, so this only affects users who deliberately enabled them. |
| FS-11 | Measured, not yet needed in anger | The muOS reference device proved the console rung is unavailable there and that the framebuffer paint reaches the panel (verified by eye on hardware, 2026-08-24). What it has not proved is the rung firing in its real case — a muOS device with no LOVE runtime installed — because the reference unit has LOVE. |

### What would move this the most

One volunteer on **dArkOS** running **Self test**. That is now the only
outstanding ask: muOS answered its half on 2026-08-25 by playing, which is what
none of these rows could be closed by a device that never started the game.
FS-1, FS-5 and FS-9 still need sessions on firmwares or builds nobody here
owns — an armhf 1.16.x for the resolver guard, the ArkOS/KMSDRM display path,
and an armhf acceptance pass. FS-2 now waits only on removing the dormant
client hooks or making explicit overrides restorable.

## Startup supervision (Phase 2, F2)

`lib/watchdog.sh` supervises every launch from client exec until it can prove
the game is drawing:

- **Progress** = the client log growing, the process accumulating CPU time, or
  the frame-metrics file growing. A frame-metrics row is the only *positive*
  proof of a frame, so when the client is writing one (`MCPE_MEASURE_FPS=1`)
  the watchdog disarms on the first row and records the `first-frame` stage.
- **Default is stall detection, not a deadline.** `MCPE_STALL_SECONDS`
  (default 90) fires only when *nothing* has changed. A first launch on a cold
  microSD card is legitimately slow, and killing a healthy start would be a
  worse bug than the hang. `MCPE_STARTUP_TIMEOUT` adds an absolute cap and is
  off by default.
- On firing it writes `logs/hang-report.txt` (process and per-thread state,
  kernel wait channel, mapped objects, last 200 log lines), terminates the
  client so the frontend can be restored, and lets the ladder escalate.

Known blind spot: a client that spins on the CPU forever looks like progress.
Closing that needs a real progress signal from inside the client, which is not
something to guess at from the outside — see FS-7.

## Deliberately not included

- **A software-rendering rung.** `llvmpipe` is a real mode in the bundled
  Weston runtime, but the only in-tree use (`downloader/run.sh`) pairs it with
  the `noop` renderer and `SDL_VIDEODRIVER=mali` for a Qt window, while
  `weston_launch.sh` would pair it with `pixman`. That combination has never
  been run against the game here. Shipping it as the last rung before
  diagnostic could easily be *worse* than rung 1, so it is left out until
  someone has actually booted the game with it.
- **A 32-bit video-driver override.** `run_bedrock32.sh` chooses kmsdrm or
  wayland from live sway/DRM state and already falls back on its own. Forcing
  a driver from the ladder would replace a correct runtime decision with a
  guess made before the device was inspected.
