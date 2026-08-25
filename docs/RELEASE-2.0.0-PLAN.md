# What has to happen before v2.0.0 is a real release

Written 2026-08-25 against `v2.0.0-rc.15`. This is the pre-publication plan: what
is blocking a stable 2.0.0, what is deliberately out of scope for it, and the
order to do it in. `docs/PLATFORM-COMPAT-PLAN.md` and `docs/ROBUSTNESS-PLAN.md`
say what the engineering work was and what remains; this file says what a
release needs on top of that.

## Scope of 2.0.0

Three decisions, made up front, because most of the work below follows from
them.

**Standard edition on Knulli, ROCKNIX and muOS is what 2.0.0 claims.** All three
have been measured on real hardware: Knulli and ROCKNIX on 2026-08-23, muOS on
2026-08-24 (capability) and 2026-08-25 (a full sign-in → download → install →
play session with sound and controls, exit 0 after 488 s).

**The RGDS dual-screen companion ships as experimental.** It is in early
development. It works on the reference RG DS, but it is one device, one
firmware, and a large amount of new surface: a companion daemon, a telemetry
bridge patched into the client, a terrain worker, touch routing, an on-screen
keyboard supervisor and a five-tab UI. The port must say so wherever a player
can choose it, so that "the minimap is wrong" reads as an expected report rather
than a broken release.

**The ArkOS family — ArkOS, dArkOS, DarkOS RE — is out of scope for 2.0.0.**
There is no reference device and never has been. Its code paths stay in the
tree: they are capability-driven, they cost nothing, and issue #1's log paid for
them. What goes is the *claim*. Nothing in the release may imply the family is
supported, and `docs/CFW-CONTRACTS.md` keeps its section marked "no reference
device" so the assumptions stay legible for whoever eventually measures them.

---

## Status

| Item | State |
|---|---|
| R1 GitHub serves rc.9 as Latest | **Done** — rc.4, rc.7, rc.8 and rc.9 flagged prerelease on 2026-08-25; `releases/latest` now resolves to v1.6, and will resolve to v2.0.0 when it publishes |
| R2 Update port broken on a default install | Error message fixed; the index rows are a post-publish step |
| R3 Compatibility table under-reports | **Done** |
| R4 Boot report missing from early exits | **Done** |
| R5 Missing runtime reported as missing game | **Done** |
| R6 Docs describe a prerelease | **Done** |
| R7 Version, channel, reproducibility gate | `VERSION` is `2.0.0`; the build and the twice-compared assembly have not been run |
| R8 Verify the built artifact on hardware | **Open** — needs the devices, and it gates publication |
| R9 Repository hygiene | **Done** |
| R10 Answer the three open issues | **Done** — #1, #2 and #10 answered on 2026-08-25 |
| R11 Changelog a release reader can use | **Done** |

---

## Blockers, ranked by how much they cost a player

### R1 — GitHub serves rc.9 as the latest release

`https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/latest`
resolves to **v2.0.0-rc.9** (2026-08-21). Four tags — rc.4, rc.7, rc.8, rc.9 —
are not flagged as prereleases, so GitHub picked the newest of those as Latest.
Everything after rc.9 is correctly flagged, which is exactly why none of them
can take the badge.

rc.9 predates every muOS fix, the PortMaster stub redirect, the framebuffer
message rung, the regex-free launch path and the DRM-node correction. A player
who lands on the repository's release page, or follows any `releases/latest`
link, is handed it. This is the cheapest possible fix and the largest one on the
list.

**Do:** flag rc.3 through rc.15 as prereleases, publish 2.0.0 as a normal
release, and confirm `releases/latest` resolves to it.

**Done, 2026-08-25.** Nine of the thirteen RC tags were already flagged; the
four that were not — rc.4, rc.7, rc.8, rc.9 — now are. `releases/latest`
resolves to **v1.6**, the last release that actually claims to be finished. That
is the honest interim answer, and it becomes v2.0.0 on publication. Confirming
the badge lands on 2.0.0 remains a post-publish step (see the checklist).

### R2 — "Update port" cannot work on a default install

`update_port.sh` defaults a new install to the **stable** channel. `release-index.json`
contains only **testing** entries. `release_select.py` requires exactly one
match, so the update path ends at:

```text
release index error: expected one minecraftbedrock.standard/stable release, found 0
```

Reproduced against the live index. Every install that has never had its channel
changed by hand is in this state, and the message does not tell the player what
to do about it.

**Do:** publish a `stable` entry per edition at 2.0.0, **and** a `testing` entry
at the same version, so installs already on testing are carried onto the stable
build rather than stranded on a channel with nothing in it.

The mechanism matters, because `stamp_payload` writes the channel into the
payload's `edition.json`, so building the same version twice with different
`--channel` values produces two archives with different SHA-256. Publishing both
would double the assets for no benefit. Build **once** with `--channel stable`,
then add a `testing` row per edition to `release-index.json` pointing at the
same asset, URL and SHA-256. `update_port.sh` writes the *device's* channel to
`config/update_channel` after a successful update, and the only identity it
checks in the downloaded payload is the edition id, so a testing-channel device
updates onto the stable archive and stays on testing.

The no-release error itself is fixed in the compatibility patch: it now names
which channel is empty and tells the player to change Update channel in
Settings, instead of reporting a count.

### R3 — The compatibility table under-reports what is known

`TESTING.md`'s per-CFW state table shows muOS as `—` on all fifteen rows, while
`docs/CFW-CONTRACTS.md` and `docs/FAILSAFES.md` both record a measured muOS
session in detail. The table is the artefact a release claim rests on and it is
the one that is wrong.

The muOS card failed on 2026-08-25 and is out of the device, so those rows
cannot be re-run before release. That is a reason to record what was measured
while it was reachable, with the date, not a reason to leave it blank.

**Do:** fill in the muOS column from the recorded evidence, date every cell, and
state plainly that the device is gone. Mark the dArkOS column out of scope for
2.0.0 rather than pending.

### R4 — An early exit leaves no boot report in the log

`mcpe_report_print` is called once, near the end of `Minecraft Bedrock.sh`, just
before the game starts. Every exit before that point — no version installed, no
LOVE runtime, a broken Python, a failed capability probe — writes
`logs/boot-report.txt` to disk but never puts it in `logs/launcher.log`.

`log.txt` is what the issue template asks for and what reporters paste. Issue #10
is the proof: the reporter pasted it into both the self-test field and the log
field, and neither copy contained the one block that would have identified the
firmware state.

**Do:** print the boot report on exit whenever it has not already been printed.
Covered by the compatibility patch below.

### R5 — A missing LOVE runtime is reported as a missing Minecraft version

With `MCPE_MENU=auto` (the default) and no LOVE 11.5 runtime, `MENU_LOVE_TXT`
falls back to empty silently, and the launcher then exits with:

> No Minecraft version installed. Copy your own APK … then launch this port again.

That message is true and irrelevant. The reason the player never saw a menu is
that PortMaster's runtime is not installed, and nothing anywhere says so. Issue
#10 selected "The launcher menu never appeared" and got this message.

The underlying muOS cause — a PortMaster stub with no runtimes behind it — was
fixed in rc.12. The misdiagnosis was not, and it applies to any firmware whose
PortMaster is incomplete.

**Do:** record the menu's availability and the paths searched in the boot
report, and name the missing runtime in the message. Covered by the
compatibility patch below.

### R6 — Every user-facing document still describes a testing prerelease

`README.md` opens with "This is a testing release"; `README.txt`,
`portmaster/minecraftbedrock/README.md` and `COMPATIBILITY.md` agree with it;
and `tests/test_docs.py` asserts the word `pending` is present in two of them,
so the guard has to move with the prose.

**Do:** rewrite the release-status paragraph in all three READMEs, regenerate
`COMPATIBILITY.md` from the registry, and update `test_docs.py` to assert the
2.0.0 claim instead of the prerelease one.

### R7 — Version, channel and the reproducibility gate

Mechanical, but it is the gate everything else passes through.

1. `VERSION` → `2.0.0`; `bottomscreen/release/edition.json` and the standard
   edition manifest follow it.
2. `python3 scripts/generate_compat_docs.py` and commit the regenerated
   `COMPATIBILITY.md`.
3. Build the pinned arm64/armhf clients, the RGDS companions and the context
   bridge from the checked-in container recipes.
4. `bash tests/run_all.sh` clean.
5. `scripts/build_releases.py --channel stable` twice; require identical
   SHA-256 for every asset.
6. `scripts/check_release_safety.py` over the standard, RGDS, source and
   Windows-helper archives; read the SBOMs.
7. Verify edition, channel, size, SHA-256 and `minimum_updater` for every
   `release-index.json` entry, including the added testing rows.
8. Rewrite the stable release-notes text in `scripts/build_releases.py`. Today
   the testing branch writes three sentences and the stable branch writes
   "Stable channel release." A first stable release needs the firmware scope,
   the RGDS experimental caveat, and the per-device self-test summaries from R8.

### R8 — Verify the built artifact on hardware before publishing

`docs/ROBUSTNESS-PLAN.md` P5, promoted to a release gate. rc.14 was published
without ever being installed on muOS because the card had died; the notes
disclosed it, which was honest and backwards.

**Do:** install the built 2.0.0 archive — the actual zip, not a deployed code
tree — on the Knulli RG34XX-SP and the ROCKNIX RG DS, run **Self test** on each, and record the summary line per
device in the release notes. Ten minutes; it would have caught the rc.12 false
"Weston runtime missing" warning before players saw it.

muOS cannot be included. Say so in the notes rather than letting the 2026-08-25
session stand in for a build it never ran.

### R9 — Repository hygiene

- `staging/` is 62 tracked files, including prebuilt client binaries and shared
  libraries, last updated for rc.3 on 2026-08-11. `RELEASE_CHECKLIST.md` opens
  by telling the reader not to release from it. A public repository should not
  carry a stale second copy of the payload that the checklist has to warn about.
- `handoff.md` is an internal working note at the repository root.
- `ANNOUNCEMENT.md` is already labelled archived; leave it.

### R10 — Answer the three open issues before publishing

- **#1** (R36S / dArkOS RE): say the family is out of scope for 2.0.0, that the
  four fixes that log produced did ship, and that a **Self test** paste is still
  the one thing that would change its status.
- **#2** (RG35XX-H / Knulli, hang at the loading bar): rc.11 added the startup
  watchdog and the breadcrumb; ask whether 2.0.0 changes the outcome and for
  `logs/hang-report.txt` if not.
- **#10** (RG35XX Pro / muOS, menu never appeared): the cause is diagnosed — a
  PortMaster stub with no LOVE runtime behind it — and fixed in rc.12; the
  misleading message is fixed by R5. Ask for a retest on 2.0.0.

Replies drafted for #1 and #2 during Phase 5 were never sent because no release
contained the fixes. 2.0.0 is that release.

**Done, 2026-08-25.** All three answered, pointing at rc.15 rather than at
`releases/latest`, and telling players to take the zip from the release page
because **Update port** cannot fetch a release until R2's index rows exist.

#10 turned out to be R1's cost, made concrete: the stub-redirect fix landed
2026-08-24 21:59 and first shipped in rc.12, while the release page was handing
that reporter rc.9. The two blockers at the top of this list are one story.

### R11 — A changelog a release reader can use

`CHANGELOG.md` is 62 KB of per-RC notes. 2.0.0 needs one entry that says what
changed since v1.6 for a player: shared data and editions, the transactional
installer, the failsafe ladder, the startup watchdog, the self test, the
on-device Google Play downloader, and the RGDS edition with its experimental
label. The RC notes stay below it as the record.

---

## The final compatibility patch — LANDED

Everything R4 and R5 asked for, the R2 error message, and the two scope
decisions made real in code rather than only in prose.

| What | Where |
|---|---|
| The boot report is printed from an EXIT trap armed before the first exit, and printing is idempotent so the normal path still prints once | `Minecraft Bedrock.sh`, `lib/common.sh` |
| Why the menu is unavailable, and every path searched for the LOVE runtime, in the boot report | `Minecraft Bedrock.sh` |
| The no-version message leads with the missing runtime when that is the cause | `Minecraft Bedrock.sh` |
| `mcpe_cfw_support` — one answer to "does this release claim this firmware", reported by the launcher and the self test | `lib/common.sh`, `selftest.sh` |
| Editions declare `stability`; RGDS is `experimental` and the launcher announces it | `edition.json` ×2, `lib/common.sh`, `Minecraft Bedrock.sh` |
| The RGDS store description and packaged README say experimental | `scripts/build_releases.py` |
| An empty update channel names itself and how to switch | `release_select.py` |
| Firmware scope and the RGDS caveat in the public, maintainer and packaged READMEs; muOS filled in and the ArkOS family scoped out | `README.md`, `README.txt`, packaged README, `TESTING.md`, `docs/CFW-CONTRACTS.md`, issue template |
| Five new contract assertions, and an execution test that runs the launcher instead of grepping it | `tests/test_portability_contracts.py`, `tests/test_launcher_early_exit.sh` |

Three things worth recording, because they differ from the sketch:

- **The execution test needed a fake `uname`.** The launcher refuses a non-ARM
  host in its first twenty lines, before anything this test is about. Rather
  than give production code a test-only architecture override, the harness
  shadows `uname` on `PATH` for the run — the same reasoning as the existing
  PortMaster stub in `tests/test_selftest_runs.sh`.
- **Running it found a defect the string tests could not.** `menu_searched`
  listed the same path twice, because `PM_CONTROL_ROOT` and `controlfolder` are
  the same directory unless a stub `control.txt` redirected one. The candidate
  list de-duplicates now, and the execution test fails if it stops.
- **One mutation is not caught by execution, and the test says so.** Removing
  the idempotency guard does not produce a duplicate on the early-exit path,
  because only the trap prints there. The case the guard protects is the normal
  path, which needs a launch; that half stays pinned by the string contract.
  Both halves were mutation-tested: seventeen reverts, sixteen caught by
  execution or contract, and the one that is not is the one named here.

## What this patch does not do

- It does not bump `VERSION` or the channel; that is R7, and it should happen
  in one commit with the regenerated `COMPATIBILITY.md`.
- It does not touch `staging/` (R9) or the GitHub release flags (R1).
- It has not been run on hardware. The launcher change is on the path every
  launch takes, so R8 is not optional for it: install the built archive on the
  Knulli RG34XX-SP and the ROCKNIX RG DS and confirm a normal launch still
  prints exactly one boot report and starts the game.

---

## Deliberately not in 2.0.0

Recorded so they are decisions rather than omissions.

- **The ArkOS family.** No device, no claim. See the scope section.
- **Failsafe removals.** Six of the eleven register rows in `docs/FAILSAFES.md`
  wait on a firmware nobody here owns. Shipping them as-is costs a conservative
  fallback nobody currently reaches.
- **Robustness plan P2, P3, P4 and P6** — the busybox-independence sweep beyond
  the launch path, the fresh-install and rollback matrix, downloader
  interruption recovery, and preferring capability over firmware name
  everywhere. All are real; none blocks a release whose gates pass on hardware.
- **The ROCKNIX sign-in browser.** It fails on `wl_egl_window_destroy`, which
  nothing on that firmware defines. That is a PortMaster/Crusty conversation,
  and the downloader is already gated off ROCKNIX.

---

## Order of work

1. R1 — flag the prereleases. Independent of everything else and it stops the
   bleeding today.
2. Compatibility patch: R4, R5, and the R2 error message.
3. R3, R6 — make the documents say what is true, with the tests moved to match.
4. R9 — hygiene, before the tree is tagged.
5. R7 — version bump, regenerate, build, verify twice, scan.
6. R8 — install the built artifact on both reachable devices, run Self test,
   record the summaries.
7. R11 — write the 2.0.0 changelog and release notes with those summaries in
   them.
8. Tag, publish, set Latest, update `release-index.json` with both channels.
9. R10 — answer the three issues, pointing at the published build.
