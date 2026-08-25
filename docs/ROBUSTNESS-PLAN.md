# Robustness plan

Written 2026-08-26, at the end of the session that shipped rc.12 through rc.14.
It is a plan, not a record: `docs/CFW-CONTRACTS.md` holds measured facts and
`docs/FAILSAFES.md` holds the failsafe register. This file says what to do next
and, at the end, what nobody has answered yet.

## Where this starts from

Three devices are reachable and all run v2.0.0-rc.14: an RG34XX-SP on muOS
2601.0 (fresh card, `192.168.1.42`), the same model on Knulli (`192.168.1.25`),
and an RG DS on ROCKNIX (`192.168.1.24`). rc.14 has now been installed from the
published artifact on the muOS card and taken all the way through Google
sign-in, download of 1.21.51.01, install and play. The RG DS passes its self
test at 17 ok / 0 warnings.

What this session actually taught, and what the plan below is built on: every
failure that cost real time came from an assumption about the *environment*
rather than from the port's own logic — a PortMaster stub that redirects, a
console that renders nothing, a frontend that is its own child's ancestor, a
`libGL` that is a `/dev/null` device, and a busybox whose regex engine started
dying mid-afternoon.

## Open investigation: 1.21.51.01 downloads slowly on muOS

Reported 2026-08-26. The comparison isolates it better than any single
measurement would:

| firmware | version | speed |
|---|---|---|
| muOS | 1.16.221.01 | fast |
| muOS | **1.21.51.01** | **20–30 minutes** |
| Knulli | 1.21.51.01 | fast |

So it is neither "muOS is slow" nor "1.21.51.01 is big" on its own — it is the
combination, which is the interesting kind of bug. Nothing has been measured
yet; the first job is to find out which phase is slow, because "download" is
four phases wearing one coat:

1. Google Play fetch (`gplaydl`), network-bound
2. SHA-256 validation of each split
3. Extraction and install into `versions/`
4. The launcher's post-install scan (`apk_groups.py`, metadata, library hash)

`logs/downloader.log` already timestamps some of this. The cheap experiment is
to re-download a version that is *already* installed on both firmwares with
per-phase timing, and to run phases 2–4 alone against the same local APK set on
both devices — that separates network from CPU/storage without needing Google at
all. Candidate causes worth keeping in mind while measuring: Wi-Fi power saving
differing between the two kernels, exfat write patterns for the larger split
set, and validation reading the whole set twice.

Whatever the answer, the port should be *reporting* this. A phase-timed line in
the boot report would have made the question answerable from a support bundle.

## Priorities

Ranked by how much failure they prevent per unit of work.

### P1 — Run the self test in CI, against captured fixtures

`tests/test_cfw_contracts.py` checks that `selftest.sh` *contains* strings. It
never executes it. That is why a false "Weston runtime missing" warning shipped
in rc.12, and why a raw shell error appeared on a fresh card (see PR #25 — real
enough to guard, never reproduced, honestly labelled).

Build a fixture tree per firmware from `tools/capture-muos.sh` output, run
`selftest.sh` against it with `MCPE_PROBE_ROOT`, and assert on the *report*: the
expected ok/warn lines, and **empty stderr**. Done when a deliberately broken
probe fails CI.

### P2 — Finish the busybox-independence sweep

The launch path no longer needs a regex engine (rc.15). The rest of the payload
still does: the launcher's path-safety check and the controller-config filters
use `awk '/re/'`, and `weston_launch.sh` still shells out to `pkill`. Neither is
fatal today — one fails closed, the other degrades — but the sweep should finish
and the contract test widen to cover the whole payload rather than six files.

Also unfinished from `docs/CODING-FOR-MUOS.md` rule 8: `tar -z` and `date +%N`
are absent on these firmwares. Every use should be guarded or replaced.

### P3 — A fresh-install and update/rollback matrix

Both reference devices had history, so first-run paths were the least-tested and
produced the most surprises. Cover, as tests where possible and as a device
checklist where not: install from the published zip onto an empty card; first
launch with no runtime; update rc.N → rc.N+1 with a version installed and worlds
present; and **rollback**, which `update_port.sh` writes to
`.minecraftbedrock.rollback` and which nothing has ever exercised.

### P4 — Make the downloader survive being interrupted

A truncated first run left the runtime half-extracted, and the next run reported
"The on-device Google sign-in helper is missing" — technically true, unhelpful,
and it cost an hour of misdiagnosis. Extraction should be atomic (stage then
rename) or resumable, and the missing-helper message should distinguish "never
installed" from "installed but incomplete".

### P5 — Verify a release on hardware before publishing, not after

rc.14 was published without ever being installed on muOS; the card had died and
the notes disclosed it. That was honest but backwards. Add a pre-publish step to
`RELEASE_CHECKLIST.md`: install the built artifact on every reachable device and
run **Self test**, recording the summary line per device in the release notes.
It is ten minutes and it would have caught the rc.12 false warning before players
saw it.

### P6 — Prefer capability over firmware name, everywhere

`MCPE_HAS_DRM` now requires the kernel to list the card, not just a node to
exist, because ROCKNIX and westonwrap both create nodes that lie. The same
scrutiny should go over audio, ABI and graphics selection: anywhere the code
branches on a firmware *name* while a capability could be measured, and a
contract test that fails when a new name-branch appears.

## Questions nobody has answered

Deliberately left open, with what is known so far.

1. **Which phase is slow for 1.21.51.01 on muOS?** Nothing is instrumented. See
   the experiment above. The answer may be boring (Wi-Fi power saving) or may be
   a real defect in validation.
2. **Should the self test ever refuse to launch the game?** Today it only
   reports. A device whose `python3` segfaults intermittently — as the dead muOS
   card's did — is one where launching produces confusing failures. There is a
   case for a hard "this device is not healthy" verdict, and a case that the
   port has no business making that call.
3. **How much of a device can a fixture honestly fake?** P1 depends on the
   answer. `/proc`, `/sys` and device nodes are easy; a Mali driver, a compositor
   and a gamepad are not. Where is the line past which a fixture is a lie?
4. **Is the ROCKNIX sign-in browser worth pursuing upstream?** It fails on one
   missing symbol (`wl_egl_window_destroy`, undefined by the Weston package, the
   Mesa package and ROCKNIX's own libEGL). That is a PortMaster/Crusty
   conversation, not a change here. Someone has to decide whether to open it.
5. **What is the port's obligation on failing hardware?** A card that silently
   corrupts binaries produced SIGILL, segfaults and a kernel oops. The port
   cannot fix that, but it currently cannot name it either. A "your storage is
   lying to you" signal is possible — `e2fsck`-style checks are not, on a
   read-write root.
6. **Do the unevidenced failsafe rungs deserve simulation?** FS-1, FS-2, FS-5 and
   FS-9 wait on firmwares nobody owns. Fixture-driven rung exercises would prove
   the ladder's *logic* without proving its effect on hardware. Worth it, or
   false comfort?
