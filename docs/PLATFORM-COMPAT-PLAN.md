# Four-CFW compatibility plan (Knulli / muOS / ROCKNIX / dArkOS)

Goal: the port launches and plays on Knulli, muOS, ROCKNIX, and dArkOS/ArkOS
without the maintainer being present. Where it cannot, it must fail loudly,
recover the frontend, and hand the user a pasteable diagnostic — never a frozen
console.

Method: ship a **ladder of conservative failsafes** first, each one recorded
with the evidence needed to delete it, then delete them as real device reports
arrive. Failsafes are treated as debt with an explicit payoff condition, not as
permanent behaviour.

---

## 1. What already exists (do not rebuild)

The platform layer is in good shape and the plan builds on it rather than
replacing it:

- `minecraftbedrock/lib/platform.sh` — capability probe (arch, loaders, DRM
  connectors/modes, fbdev, Mali/Mesa, ALSA/Pulse/PipeWire, gamepads, touch),
  driven by `MCPE_PROBE_ROOT` so it is testable off-device.
- `minecraftbedrock/lib/abi.sh` — ABI policy separated from launch mechanics.
- `tests/test_platform.sh` — host fixtures already covering Knulli/H700,
  muOS/H700, ROCKNIX/RGDS, ROCKNIX/RK3566, and dArkOS/RK3326.
- `run_bedrock32.sh:302-370` — KMSDRM panel-mode detection. This is the fix for
  issue #1's `Couldn't find any matching video modes`, landed after that report.
- `run_bedrock.sh:236-280` — three-way audio triage (pulse socket /
  PipeWire-without-pulse / bare ALSA). This is the muOS Jacaranda audio fix.
- `weston_launch.sh:416` — shutdown watchdog.
- `create_support_bundle.sh` — redacted bundle safe to attach to public issues.
- `compat/compatibility.json` + `version_env.py` — per-version compatibility
  registry and patch gating.

---

## 2. Field evidence being addressed

| Source | Device / OS | Symptom | Status |
|---|---|---|---|
| Issue #1 | R36S / dArkOS RE, armhf 1.16.221.01 | `Couldn't find any matching video modes`, signal 6 | Fixed by panel-mode detection; **unverified on device** |
| Issue #1 | same | `[ALSOFT] Failed to create PipeWire event context`, `can't load config client.conf`, RTKit failure | **Open — see A2** |
| Issue #1 | same | `Killed ... love.aarch64` from gptokeyb on an armhf device | **Open — see A4** |
| Issue #2 | RG35XX-H / Knulli, arm64 1.16.221.01 | Launcher works; game sticks at the loading bar, console freezes, no log | **Open — see B1** |
| Reddit (kepin_7790) | RG35XX-H / muOS Jacaranda | Crash on launch | Fixed in v1.4 |
| Reddit | same | No audio (ALSA "Device or resource busy" under PipeWire) | Fixed in v1.4.1 |
| Reddit | same | **"Game always exits before the character menu when Wi-Fi is on; offline always works"** | **Open — see A1** |
| Reddit | same | No arm64-v8a APK obtainable from mirrors | Addressed by mcbedrock-get + on-device downloader |

---

## 3. Confirmed defects found while reading the tree

### A1 — The Wi-Fi startup crash guard is unreachable

`isNetworkEnabled()` in `source_release/mcpelauncher-client.patch:544-552` can
report "no network" via `MCPE_FAKE_NO_NETWORK=1`, which is exactly the escape
hatch for the reported "crashes with Wi-Fi on, fine offline" behaviour.

**No shell script in the repo ever sets that variable.** It is reachable only
by a user who reads the C++ patch.

The other guard, `patchOldHttpResolveCrash()`
(`source_release/mcpelauncher-client.patch:627`), is gated three ways:
`#if !defined(__aarch64__) return;`, a hardcoded
`instructionOffset = 0x060a01e4`, and `gameDir.find("1.16.221.01")`. So it can
only ever fire on **arm64 1.16.221.01**.

Yet `compat/compatibility.json` lists `http_resolver_guard` for
**1.16.40.02/armhf**, **1.16.221.01/armhf**, and **1.17.41.01/arm64** — three
combinations where the patch provably returns early. The registry promises
protection that does not exist, and no fallback takes over.

### A2 — The 32-bit path has no audio triage at all

`run_bedrock32.sh:167` is the entire audio configuration:

```sh
export SDL_AUDIODRIVER="${MCPE_SDL_AUDIODRIVER:-alsa}"
```

`ALSOFT_DRIVERS` is never set, so OpenAL Soft walks its built-in preference
list and tries PipeWire first. On dArkOS RE, PipeWire is present but its client
config is not — producing precisely the issue #1 log lines. The careful triage
that fixed muOS on the 64-bit path (`run_bedrock.sh:236-280`) was never ported
across.

### A3 — `ARM64_USABLE` trusts `uname -m` alone

`run_bedrock.sh:41-46` accepts `uname -m = aarch64` as sufficient proof the
64-bit client can run. dArkOS RE is a 64-bit kernel with an armhf userland
(`/usr/lib/arm-linux-gnueabihf/libc.so.6` in the issue #1 log), and reported
`usable: 64=1` there. Today that is harmless because the version was 32-bit
only; with an arm64 APK installed the launcher would choose a client the device
cannot load.

### A4 — gptokeyb is told the wrong binary name

`Minecraft Bedrock.sh:749` runs `$GPTOKEYB "love.${DEVICE_ARCH:-aarch64}"`.
On armhf CFWs where `DEVICE_ARCH` is unset, the helper is pointed at a process
that does not exist, so menu input never gets mapped. Visible in the issue #1
log as the helper being killed.

### A5 — CFW identity is derived four times, differently

`is_muos()` exists in `Minecraft Bedrock.sh:86`, `weston_launch.sh:68`, and
`run_bedrock32.sh:44`; `is_knulli()` in `weston_launch.sh:77` and
`migrate_data.sh:108`. ROCKNIX and ArkOS have **no** detector — they are
inferred incidentally from `pidof sway` and from falling through to `generic`.
Every per-CFW behaviour added from here compounds this drift.

### A6 — Nothing watches startup

`weston_launch.sh` has a shutdown watchdog only; it arms after
`Invoking stop activity callbacks`. A hang *before* first frame — issue #2 —
has no timeout, no diagnostic, and no frontend restoration. The user's only
recovery is a power cycle, which is also why that issue carries an empty log
field.

---

### A7 — (found while implementing Phase 0) a cached identity would have hidden every per-CFW branch

The consolidated resolver initially cached its answer on first use. `CFW_NAME`
only exists after PortMaster's control files are sourced, so any caller that
asked before that point would pin `unknown` for the rest of the launch and
silently switch off Knulli's hidden shared root, muOS's frontend handoff, and
every other per-CFW branch at once — with no error anywhere.

`tests/test_migration.sh` caught it immediately. The cache is now keyed on
`CFW_NAME` + `MCPE_CFW_OVERRIDE` + `MCPE_PROBE_ROOT` and re-resolves whenever
they change, with a regression test pinning the late-`CFW_NAME` case.

---

## 4. Phase 0 — Ground truth (prerequisite for everything else) — **LANDED**

**0.1 Canonical CFW identity.** Resolve once in `lib/platform.sh`, export as
`MCPE_CFW` ∈ `{knulli, muos, rocknix, arkos, batocera, unknown}` plus
`MCPE_CFW_CONFIDENCE` ∈ `{explicit, inferred}`. Order of evidence: `CFW_NAME`
from PortMaster control.txt → `/etc/os-release` → filesystem markers
(`/opt/muos`, `/opt/system/Tools/PortMaster` + ArkOS release file,
`/storage/.config` + sway for ROCKNIX, `/userdata` for Knulli/Batocera).
Delete the four ad-hoc detectors (A5) and have them read `MCPE_CFW`.

**0.2 Stage breadcrumb.** `logs/stage.txt` overwritten with a single token at
each milestone: `boot`, `payload`, `migrate`, `probe`, `menu`, `version`,
`abi`, `runtime`, `client-exec`, `window`, `first-frame`, `shutdown`, `done`.
It survives a hard power-off, so the next launch can say *"last time this
device stopped at `client-exec`"* — the missing information in issue #2.

**0.3 Boot report.** One block at the top of every `launcher.log`: CFW +
confidence, profile, graphics backend, audio backend, ABI and why, panel mode
and its source, Bedrock version + fingerprint match, and the list of active
failsafes. Today this is scattered across a dozen `echo` lines.

**0.4 Bundle additions.** Add `stage.txt`, `failsafe-ledger.tsv`, and
`launch_state.json` to `create_support_bundle.sh`.

### What landed

| Item | Where |
|---|---|
| `mcpe_cfw_from_name`, `mcpe_resolve_cfw`, `mcpe_is_cfw` | `minecraftbedrock/lib/common.sh` |
| `MCPE_CFW` / `MCPE_CFW_CONFIDENCE` emitted with the capability probe | `minecraftbedrock/lib/platform.sh` |
| Four ad-hoc detectors deleted, all callers switched | `Minecraft Bedrock.sh`, `lib/migrate_data.sh`, `weston_launch.sh`, `run_bedrock32.sh` |
| `mcpe_stage` / `mcpe_stage_begin`, `stage.txt` + `stage.prev.txt` | `lib/common.sh`, wired through both launch paths |
| `mcpe_report_begin/set/print`, `logs/boot-report.txt` | `lib/common.sh`, `Minecraft Bedrock.sh`, `run_bedrock.sh`, `run_bedrock32.sh` |
| Breadcrumb, boot report and CFW identity in the bundle | `create_support_bundle.sh` |
| Identity fixtures for all four CFWs, layout inference, cache-key regression, breadcrumb round-trip | `tests/test_platform.sh` |
| Contract tests: one resolver, ordered stages, required report fields | `tests/test_portability_contracts.py` |

Two behaviour changes worth knowing about, both consequences of detection
getting better rather than of new policy:

- A Knulli install whose PortMaster control files do not set `CFW_NAME` is now
  recognised from `/etc/os-release` and takes the hidden shared-data root it
  always should have. The merge is preflighted and aborts on any collision
  without touching user data, and `tests/test_migration.sh` covers it.
- `MCPE_IS_MUOS` is now derived from `MCPE_CFW` in `lib/platform.sh` instead of
  being set by hand early in the entry script. It is retained only for payload
  scripts that still read it directly.

---

## 5. Phase 1 — The failsafe ladder — **LANDED**

A launch-attempt state machine in `config/launch_state.json`, keyed by
`(MCPE_CFW, bedrock version, ABI)`. If the previous attempt for that key did
not reach `first-frame`, the next launch **auto-escalates one rung** and says so
on screen.

| Rung | Name | Behaviour |
|---|---|---|
| L0 | Tuned | Current behaviour: measured presets, affinity pinning, performance governor |
| L1 | Conservative | `MCPE_FAKE_NO_NETWORK=1`, VSync on, 30 fps cap, no affinity pinning, no governor change, UI scale from panel geometry, minimum render distance |
| L2 | Minimal | L1 plus graphics fallback (arm64 `crusty_x11egl` → `wayland`/pixman; armhf `kmsdrm` → `x11` → `wayland`) and the most conservative audio backend the probe can prove works |
| L3 | Diagnostic | Do not start Minecraft. Run the self-test, write the bundle, print how to report |

Rules that keep this honest:

- Every rung change appends to `logs/failsafe-ledger.tsv`:
  timestamp, key, rung, trigger, outcome.
- Reaching `first-frame` and a clean exit **de-escalates one rung** on the next
  launch, so a one-off failure does not permanently degrade a working device.
- `MCPE_SAFE_MODE=0|1|2|3` pins a rung manually; a menu entry exposes it.
- Rung ≥ L1 is stated on screen and in the log — silent degradation is worse
  than the bug.

### What landed

The full register of rungs, knobs and removal criteria is
[docs/FAILSAFES.md](FAILSAFES.md).

| Item | Where |
|---|---|
| Launch-attempt state machine, ledger, atomic state file | `minecraftbedrock/failsafe_state.py` |
| What each rung changes, in one readable place | `minecraftbedrock/lib/failsafe.sh` |
| plan → apply → announce → launch → record | `Minecraft Bedrock.sh` |
| `safe_mode` in settings.cfg and in the launcher menu | `Minecraft Bedrock.sh`, `menu/main.lua` |
| Register of every failsafe and its exit criterion | `docs/FAILSAFES.md` |
| State-machine behaviour (12 cases) | `tests/test_failsafe.py` |
| What the rungs actually do to the environment | `tests/test_failsafe_apply.sh` |
| Ladder cannot degrade silently, permanently, or undocumented | `tests/test_portability_contracts.py` |

Three decisions worth recording, because they differ from the sketch above:

- **De-escalation needs two clean launches and respects a floor.** The sketch
  de-escalated on any success, which would make a device that only works at L1
  alternate good and bad launches forever. An observed startup failure now
  raises a floor the ladder will not drift back below.
- **Only an observed failure is permanent.** There is no first-frame signal
  until Phase 2, so a launch that never returns is inferred from the breadcrumb
  — and that inference cannot tell a freeze apart from a player pulling the
  power after an hour. It therefore escalates but does *not* raise the floor,
  so it self-corrects. This weakening is FS-7 and is deleted when F2 lands.
- **A late crash costs nothing.** A non-zero exit after the 120 s startup
  window leaves the rung alone; crashing after a long session is not a startup
  problem and a more conservative profile would not address it.

Two candidate rungs were deliberately **not** shipped, because neither could be
justified from this tree: an `llvmpipe` software-rendering rung (the only
in-tree use pairs it with a different renderer, for a Qt window, never the
game) and a 32-bit video-driver override (`run_bedrock32.sh` already decides
from live DRM/sway state and would be overridden by a blind guess). Both are
recorded under "Deliberately not included" in `docs/FAILSAFES.md`.

---

## 6. Phase 2 — Targeted fixes for the reported failures — **LANDED**

**F1 (fixes A1, the Reddit Wi-Fi crash).** Wire `MCPE_FAKE_NO_NETWORK`.
Default it **on** whenever `MCPE_PROFILE_CLASS=legacy_1_16` *and*
`patchOldHttpResolveCrash` cannot apply — i.e. ABI ≠ arm64, or version name ≠
1.16.221.01, or the library fingerprint does not match the registry entry. Add
an `offline_mode` key to `settings.cfg` and a menu toggle labelled for what it
does ("Offline mode — fixes crash-on-launch when Wi-Fi is on"), because LAN
multiplayer is a headline feature and users must be able to trade it back.
Separately, correct `compatibility.json` so `http_resolver_guard` is only
claimed where the patch can actually fire.

**F2 (fixes A6, issue #2).** Startup watchdog in `weston_launch.sh` and
`run_bedrock32.sh`, armed from client exec until the first-frame marker.
Liveness signal: the existing `MCPE_FRAME_METRICS` file
(`mcpelauncher-client.patch:113-140`) written to a scratch path for the first
N seconds regardless of the user's FPS setting, plus log growth and process CPU
time as backstops. On timeout (default 120 s, `MCPE_STARTUP_TIMEOUT`): capture
`/proc/<pid>/status`, `wchan`, `maps` summary and the last 200 log lines into
`logs/hang-report.txt`; terminate; restore the frontend; escalate a rung; show
the user what happened.

**F3 (fixes A2).** Extract the audio triage from `run_bedrock.sh:236-280` into
`lib/audio.sh` and call it from **both** launch paths. Add a negative check for
"PipeWire present but unusable" (no reachable socket, or no loadable client
config) so OpenAL Soft is never handed `pipewire` on a dArkOS-style host.

**F4 (fixes A3).** Require the aarch64 loader to exist *and* be executable, or
a successful trivial exec of the shipped 64-bit client, before setting
`ARM64_USABLE=1`. Same treatment for `ARMHF_USABLE`.

**F5 (fixes A4).** Derive the gptokeyb target from the resolved ABI and the
LOVE runtime actually found, not a hardcoded `aarch64` default.

### What landed

| Fix | Where | Test |
|---|---|---|
| F1 network policy + registry correction | `Minecraft Bedrock.sh`, `compat/compatibility.json`, `menu/main.lua` | `test_portability_contracts.py` |
| F2 startup watchdog | `lib/watchdog.sh`, `weston_launch.sh`, `run_bedrock32.sh` | `tests/test_watchdog.sh` |
| F3 shared audio triage | `lib/audio.sh`, both launch paths | `tests/test_audio.sh` |
| F4 loader-based ABI check | `lib/abi.sh`, `run_bedrock.sh` | `tests/test_abi.sh` |
| F5 gptokeyb target from the resolved LOVE runtime | `Minecraft Bedrock.sh` | `test_portability_contracts.py` |

Four decisions worth recording:

- **The registry was claiming guards that cannot fire.** Both in-client guards
  are wrapped in `#if !defined(__aarch64__)`, and the HTTP-resolver one also
  requires the game directory to contain `1.16.221.01`. The registry listed
  them on 1.16.40.02/armhf, 1.16.221.01/armhf and 1.17.41.01/arm64, so the port
  believed it was protected where it was not and nothing took over. Those
  entries are now empty, with the reason recorded, and a contract test keeps
  the registry honest against the patch source.
- **Offline mode is not on by default everywhere.** The plan called for
  defaulting `MCPE_FAKE_NO_NETWORK=1` for unguarded legacy builds; that is what
  shipped, but LAN multiplayer is one of this port's better features, so it is
  scoped to `legacy_1_16` builds with no working guard, says on screen that LAN
  is off, and `network=auto|on|off` overrides it from settings and the menu.
- **The watchdog detects a stall, not a deadline.** An absolute startup timeout
  would kill a healthy first launch on a cold microSD card, which is worse than
  the bug. The absolute cap exists (`MCPE_STARTUP_TIMEOUT`) but is off by
  default. The blind spot — a client that spins forever — is documented rather
  than papered over, because closing it needs a real in-client progress signal.
- **No new in-client markers.** The shipped clients are prebuilt and their
  SHA-256 is asserted by the contract tests, so the watchdog had to work from
  externally observable state only.

The 1.16 registry note in section 3 assumed the guard's `gameDir` check never
matched this port's version directories. That came from a v1.x log
(`versions/minecraft-1-16-221`); the 2.0 installer names them
`1.16.221.01-<code>-<abi>`, so the guard does match on current arm64 installs.
It still cannot fire on armhf or on any other version, which is what F1 covers.

---

## 7. Phase 3 — Per-CFW conformance contracts — **LANDED**

One documented contract per CFW, each backed by a fixture in
`tests/test_platform.sh` asserting `MCPE_CFW`, and a script-level assertion
test in the style of the existing `tests/test_portability_contracts.py`.

**Knulli** — emulatorlauncher owns the ES lifecycle; the port must never stop
ES. Hidden shared-data root (ES recursively inventories visible directories).
`/dev/tty1` messaging is available. H700 → Mali backend, fbdev geometry from
`fbset` visible dimensions, not `virtual_size`.

**muOS** — frontend handoff via `frontend.sh`/`muxlaunch`, restart through
`/opt/muos/script/mux/frontend.sh launcher` with the port's env unset. Split
install (`/roms/Ports/*.sh` + `/ports/minecraftbedrock/`). PipeWire with
`PIPEWIRE_RUNTIME_DIR=/run` and no pulse socket. Both `/mnt/mmc` and
`/mnt/sdcard` roots, `MUOS` uppercase.

**ROCKNIX** — sway owns DRM master, so KMSDRM must never be selected; the game
nests as a Wayland client. Adopt `XDG_RUNTIME_DIR`/`WAYLAND_DISPLAY`/`SWAYSOCK`
from the sway process when launched over SSH. No `/dev/tty1` surface — messages
go to the log. busybox: no `nproc`, no `timeout` guarantee. pipewire-pulse.

**dArkOS / ArkOS** — PortMaster at `/opt/system/Tools/PortMaster`,
`ESUDO=sudo`. Direct KMSDRM; ES may still hold DRM master (already diagnosed at
`run_bedrock32.sh:358`) — decide and document whether the port stops it or
refuses with an explanation. armhf userland on a possibly-64-bit kernel (A3).
Partial PipeWire (A2). This is the least-covered CFW and should get the most
conservative default rung until a device report exists.

### What landed

The contracts live in [docs/CFW-CONTRACTS.md](CFW-CONTRACTS.md), with every
clause marked **measured** (observed on a reference device, dated) or
**assumed**. `tests/test_cfw_contracts.py` asserts the script-level clauses;
`tests/test_platform.sh` asserts the capability clauses.

Two reference devices were captured read-only on 2026-08-23 — an RG34XX-SP on
Knulli and an RG DS on ROCKNIX — and the Phase 0-2 resolvers were run on both.
All produced correct results: identity, profile, backend, panel geometry, audio
backend, loader presence and the stage breadcrumb.

Four things the real hardware changed:

- **The identity work is a robustness win, not a rescue.** Both devices do
  resolve `CFW_NAME` correctly at launch (`knulli`, `ROCKNIX`) — it is derived
  by `device_info.txt`, not written in `control.txt`, which an early read-only
  probe of mine missed. So the previous CFW_NAME-only detection did work on
  these two. What Phase 0 actually buys is one resolver instead of four drifted
  ones, an identity for ROCKNIX and the ArkOS family that never existed, and an
  os-release fallback for hosts where the PortMaster chain is not sourced or
  does not recognise the firmware. Knulli's os-release is also why that fallback
  must match across all fields at once: field-by-field, the first hit says
  Batocera.
- **The fixtures were wrong in ways that mattered.** They asserted
  `compatible=allwinner,h700`; the device reports `allwinner,h616` plus
  `arm,sun50iw9p1`, and the `h700` profile only matches because of the SoC
  clause. They also gave Knulli a `/dev/dri` it does not have. Both fixtures
  now carry captured strings, and the two firmwares with no device behind them
  are labelled as constructed.
- **Two host assumptions were confirmed by absence.** `nproc` really is missing
  on ROCKNIX (busybox), and `readelf` really is missing on Knulli — so the
  contract test now forbids anything on the launch path from depending on it.
- **The corrected Knulli detection is a no-op on the reference device.** It is
  already on the hidden `.minecraftbedrock-data` root with the symlinks in
  place, so the newly-working detection agrees with the on-disk state rather
  than triggering a migration. ROCKNIX resolves to `rocknix` and stays on the
  visible root, as the contract requires.

The contract assertions were mutation-tested: removing the Knulli ES guard,
ungating the hidden shared root, dropping the sway environment adoption,
removing the `nproc` fallback, removing the ArkOS layout marker, and
introducing a `readelf` dependency are each caught.

Neither device has run the new launcher end to end yet — the capture validated
the resolvers, not a full game launch. muOS and dArkOS remain unmeasured, which
is what Phase 4's self-test is for.

---

## 8. Phase 4 — Self-test that does not need Minecraft — **LANDED**

`selftest.sh`, runnable from the menu and from SSH, reporting pass/warn/fail
for: CFW identity, arch and loaders, PortMaster control discovery, LOVE runtime,
Weston runtime checksum, `/dev/dri` access and connected modes, EGL/GLES dlopen
for the selected ABI, audio device open on the chosen backend, gamepad
enumeration and mapping, writable game/shared/profile dirs, free space,
installed versions and fingerprints. Output is short, redacted, and pasteable.

This turns *"it crashes"* into a structured report before anyone installs an
APK, and it is what the issue template should ask for.

### What landed

`minecraftbedrock/selftest.sh`, reachable over SSH and from the launcher menu
(**Self test**). It never starts the game, works before any Bedrock version is
installed, prints `[ ok ] / [warn] / [FAIL]` per check with a one-line verdict,
saves a redacted copy to `logs/selftest.txt`, and exits non-zero only when the
device genuinely cannot run the port.

Run on both reference devices, where it reported 17 ok / 0 failures on each.
Doing so immediately found three defects, two of them pre-existing:

- **The redaction filter was destroying Bedrock versions.** Version strings are
  shaped exactly like IPv4 addresses, so `1.16.221.01` and
  `1.14.60.5-943146005-arm64` were being rewritten to `REDACTED_IP` — in
  `create_support_bundle.sh` as well, meaning **every support bundle ever
  produced had its single most useful field deleted**. Version-shaped tokens
  now have their dots protected before the address filter runs and restored
  after. `tests/test_redaction.sh` pins both halves: addresses, emails and
  credentials are still removed, versions and hashes survive.
- **An unusable extra version condemned the whole device.** An installed
  1.14.60.5 (below the supported range) produced a `FAIL` and "this device
  cannot run the port", on a device with three working versions. Only a
  complete absence of playable versions is a failure now.
- **A false alarm about client libraries.** `libX11.so.6` reports unresolved on
  Knulli because the Weston runtime supplies it at launch and is not mounted
  during a self-test. The check now attributes display libraries to the Weston
  runtime and fails only on genuinely missing ones.

The first of those is the clearest argument for this phase: the self-test was
built to get facts out of muOS and dArkOS users, and the first thing it did was
prove the existing reporting path had been silently discarding facts.

---

## 9. Phase 5 — Validation and the reporting funnel — **LANDED (outreach pending approval)**

- Extend `TESTING.md` with a per-CFW acceptance checklist: install, launch,
  first frame, audio, controls, text entry, world load, LAN, clean exit,
  immediate relaunch, frontend restored.
- Add a "paste your self-test output" field to
  `.github/ISSUE_TEMPLATE/bug_report.yml`, and a CFW dropdown covering all four.
- Reply on the two open issues with the current build and the self-test. Issue
  #1's reporter has an R36S/dArkOS RE — the least-covered platform in the
  matrix — and issue #2's has an RG35XX-H/Knulli, which is the exact device
  behind the untriaged hang.
- The muOS tester from Reddit offered to keep testing; muOS Jacaranda on
  RG35XX-H is worth treating as a standing check before each release.

### What landed

- `.github/ISSUE_TEMPLATE/bug_report.yml` now leads with the self test, adds a
  firmware dropdown covering all four CFWs, and asks how far the launch got —
  pointing at `logs/stage.txt` / `stage.prev.txt` and `logs/hang-report.txt`.
  Issue #2 arrived with an empty log field because a frozen device leaves
  nothing behind; those three files are what survive that.
- `TESTING.md` gains a 15-row per-CFW acceptance checklist and a filled-in
  status table. It makes the gap explicit: Knulli and ROCKNIX pass rows 1-6 and
  12-15, while muOS and dArkOS cannot progress past row 1 without a volunteer.
- `tests/test_cfw_contracts.py` pins both, so the template cannot lose the self
  test ask and the checklist cannot lose its rows.

**Outreach is drafted, not sent.** Replies for issues #1 and #2 and a message
for the muOS reporter are written and waiting on approval. They are deliberately
not posted yet: every fix they describe is uncommitted, no release contains
them, and `selftest.sh` — which all three ask the reporter to run — does not
exist in any published build. Posting before a release would ask people to run
something they cannot get.

---

## 10. Phase 6 — Removing the failsafes — **LANDED**

`docs/FAILSAFES.md` holds one row per failsafe: id, what it does, which report
justified it, **the evidence required to delete it**, and current status.

`tests/test_failsafes.py` asserts that every `MCPE_FAILSAFE_*` /
`MCPE_SAFE_MODE` reference in the shipped scripts has a matching row, so a
failsafe cannot quietly become permanent.

Example removal criteria:

| Failsafe | Delete when |
|---|---|
| F1 offline-by-default on legacy 1.16 | Three independent reports of Wi-Fi-up launch succeeding on that ABI/version, or the resolver guard is generalised beyond the arm64 1.16.221.01 offset |
| L1 default rung on dArkOS | One full dArkOS acceptance pass in `TESTING.md` |
| F2 startup watchdog | Never — this one is permanent; only its timeout is tunable |
| F4 loader exec probe | Keep; cost is one exec |

### What landed

`tests/test_failsafes.py` reads the knobs straight out of `lib/failsafe.sh`
rather than from a list kept by hand, and asserts that each one has a register
row, that every row states why it exists and how it ends, that the ids are
unique and contiguous, and that every row carries a status saying what is still
missing. It replaces the weaker check that lived in the portability contracts.

Writing it immediately found four knobs the rungs change that the register had
never mentioned — `MCPE_MAX_FPS`, `MCPE_VSYNC`, `MCPE_PREWARM_GAMEPLAY_ASSETS`
and `MCPE_DISABLE_AUTO_COMPACTION` — now registered as FS-9 and FS-10. That is
the failure mode this phase exists to prevent, caught on its first run against
a register I had written myself two phases earlier.

The enforcement was mutation-tested: adding an unregistered knob to a rung,
replacing an exit criterion with a placeholder, and deleting a status row are
each caught. The third initially slipped through because the check looked for
the id anywhere in the section and the prose beneath the table names several
ids; it now requires an actual table row.

### The review, and why nothing was removed

All ten failsafes were reviewed against v2.0.0-rc.11 on both reference devices.
**None could be removed**, and the reason converges on one thing: six of the ten
criteria depend on muOS or the ArkOS family, and neither has a device. FS-2 to
FS-5 and FS-9 are now *partly* evidenced — the profiles, governors, capability
probe, Crusty context hand-off and frame budget all held at rung 0 on Knulli and
ROCKNIX — but partial evidence is not an exit criterion, and the register says
so rather than quietly promoting them.

The single input that would move the most rows is one volunteer running **Self
test** on muOS and one on dArkOS. That is what Phase 4 was built to make cheap.

---

## 11. Suggested order of work

1. Phase 0 (identity, breadcrumb, boot report) — everything downstream reads it.
2. F1 and F3 — two confirmed defects with named victims, both small.
3. F2 — converts the worst user experience (frozen console) into a report.
4. Phase 1 ladder — needs 0 and F2 in place to be meaningful.
5. F4, F5, Phase 3 contracts and fixtures.
6. Phase 4 self-test, then Phase 5 outreach with something worth testing.
7. Phase 6 bookkeeping, from the first failsafe onward.
