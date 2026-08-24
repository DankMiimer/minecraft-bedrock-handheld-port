# Per-CFW conformance contracts

What the port must do on each firmware, and why. Every clause is marked
**measured** (observed on a reference device, with the date) or **assumed**
(derived from code, logs or reports, and still unverified).

`tests/test_cfw_contracts.py` asserts the script-level clauses.
`tests/test_platform.sh` asserts the capability clauses against fixtures built
from captured device output.

## Reference devices

| CFW | Device | Build | Captured |
|---|---|---|---|
| Knulli | Anbernic RG34XX-SP | Knulli 20260511 (Batocera.linux 42 base), kernel 4.9.170 | 2026-08-23 |
| ROCKNIX | Anbernic RG DS | ROCKNIX 20260710 nightly, kernel 7.0.2, RK3566/RK3568 | 2026-08-23 |
| muOS | Anbernic RG34XX-SP | muOS 2601.0 (JACARANDA), kernel 4.9.170, Allwinner H700 | 2026-08-24 |
| dArkOS | — | — | none |

One firmware has no reference device. Its contract is written from the code and
from a field report, and is marked accordingly; it is the one most likely to be
wrong.

The muOS column was captured on the same RG34XX-SP hardware as the Knulli
reference, which makes the pair a controlled comparison: where the two differ,
the cause is the firmware and not the device.

---

## Knulli

**Identity — measured.** `/etc/os-release` reads `NAME=Batocera.linux`,
`PRETTY_NAME="Batocera.linux 42"`, `ID=buildroot`, and announces itself only in
`OS_NAME="knulli"`. `control.txt` itself contains no `CFW_NAME` assignment, but
`device_info.txt` — which the launcher sources immediately after it — derives
one at runtime, and on this device that resolves to `CFW_NAME=knulli`
(`CFW_VERSION=scarab`). A real launch confirmed it.

> So `CFW_NAME` is the primary evidence here and it is correct. The os-release
> path is the fallback for hosts where the PortMaster chain is not sourced or
> does not recognise the firmware — and it must match across all fields at
> once, because field-by-field the first hit says Batocera. The resolver
> orders derivatives ahead of their upstreams for exactly that reason.

**Shared data — measured.** The reference device keeps its shared tree at the
hidden `ports/.minecraftbedrock-data`, with `apk`, `versions`, `profiles` and
`backups` symlinked into the game directory. Knulli's EmulationStation
recursively inventories every visible directory under `roms/ports`, and an
extracted Bedrock version is tens of thousands of files. Dot-directories are
skipped, so the hidden root is what keeps the Ports menu usable.

**Frontend — measured.** `emulationstation` is running, `/etc/init.d/S31emulationstation`
exists, `emulatorlauncher` is on `PATH`, and sway is not running. PortMaster's
`emulatorlauncher` owns the ES lifecycle for the duration of a port, so the
port must **not** stop ES itself: Scarab's stop action can block for 20 seconds
and leave the wrapper alive, producing two input owners.

**Graphics — measured.** No `/dev/dri` at all. `/dev/disp` and `/dev/mali0` are
present, `/dev/fb0` reports `virtual_size` `720,960` for a physically 720x480
panel. The capability probe must therefore select the `mali` backend and must
take the visible geometry from `fbset`, not from `virtual_size`.

**Device identity — measured.** `model` is `Anbernic RG34XX-SP` and
`compatible` is `allwinner,h616` + `arm,sun50iw9p1`. It never says "h700", so
the `h700` profile must continue to match on `sun50iw9`.

**Audio — measured.** PipeWire is running and a Pulse socket exists at
`/var/run/pulse/native`; the triage selects the Pulse path. ALSA `pulse` and
`pipewire` PCM plugins are present under both `/usr/lib` and `/usr/lib32`.

**ABI — measured.** Both loaders are present (`/lib/ld-linux-aarch64.so.1`,
`/lib64/...`, and `/lib/ld-linux-armhf.so.3`), but there is no `/dev/dri`, so
the 32-bit client is correctly unusable and arm64 is selected.

**Tooling — measured.** `python3` 3.12.8, `timeout`, `nproc`, `flock`, `fbset`,
`unzip`, `pidof` all present. **`readelf` is absent**, so nothing on the launch
path may depend on it.

**Storage — measured.** Root is a 256 MB overlay; `/tmp` is a 990 MB tmpfs.
Scratch files belong in `/tmp`.

---

## ROCKNIX

**Identity — measured.** `/etc/os-release` sets `OS_NAME="ROCKNIX"`, and
`device_info.txt` resolves `CFW_NAME=ROCKNIX` (`CFW_VERSION=20260710`).
`control.txt` (`/storage/roms/ports/PortMaster`) sets `directory="roms"` and
`ESUDO=""`. `/storage/.config` and `/storage/roms` exist, so layout inference
would reach `rocknix` too. All three routes agree.

**Compositor — measured.** sway is running and EmulationStation runs under it.
There is no `/etc/init.d/S31emulationstation`. sway owns DRM master, so the
KMSDRM path must never be selected here; the game nests as a Wayland client.

**Session adoption — measured.** A launch over SSH has no session environment:
`XDG_RUNTIME_DIR` is `/var/run/0-runtime-dir` inside the sway process and the
IPC socket is `/run/0-runtime-dir/sway-ipc.0.sock`. The launcher must adopt
`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY` and `SWAYSOCK` from the running sway
process rather than assuming a login session.

**Shared data — measured.** The reference device uses the **visible**
`ports/minecraftbedrock-data`, which is correct: the hidden root is a Knulli
workaround and must not leak to other firmwares. `/storage/roms/ports` and
`/roms/ports` are the same tree.

**Graphics — measured.** Two connected DSI connectors, both `640x480`, plus
`/dev/dri/card0` and `/dev/mali0`. `model` is `Anbernic RG DS` and `compatible`
is `anbernic,rg-ds` + `rockchip,rk3568`, so the RGDS profile matches on the
model string. This device takes the separately versioned RGDS edition.

**Audio — measured.** PipeWire and pipewire-pulse are both running, with
sockets at `/run/pulse/native`, `/var/run/pulse/native` and
`/run/pipewire/pipewire-0`. The triage resolves the Pulse path via
`/run/0-runtime-dir/pulse/native` — reached through the
`/run/*-runtime-dir/pulse/native` candidate, which is the only one that matches
on this firmware.

**Tooling — measured.** `python3` 3.13.5, `timeout`, `flock`, `fbset`, `unzip`,
`readelf`, `pidof` present. **`nproc` is absent** (busybox), so core counting
must fall back to `/proc/cpuinfo`.

**Storage — measured.** The root filesystem is a read-only 1.3 GB loop mount at
100% use. Nothing may be written outside `/storage` and `/tmp` (1.5 GB tmpfs).

---

## muOS

**Identity — measured.** `/etc/os-release` reads `NAME=MustardOS`, `ID=muos`,
`PRETTY_NAME="MustardOS 2601.0 (JACARANDA)"`. At launch `CFW_NAME=muOS`, so the
resolver reports `muos` with `explicit` confidence. Note that PortMaster's own
`device_info.txt` on this device reads `CFW_NAME="Unknown"`; the value the port
sees is set later in the control chain, so the os-release path has to stay
correct as the backstop.

**Device identity — measured.** `model` is the bare SoC string `sun50iw9`, not a
product name, while `compatible` is `allwinner,h616` + `arm,sun50iw9p1` — the
same pair the Knulli reference device reports for the same hardware. The `h700`
profile must therefore continue to match on the compatible; matching on `model`
would work on Knulli and fail here.

**PortMaster root — measured.** `/roms/ports/PortMaster` contains `control.txt`
and nothing else. That file's first act is
`export controlfolder="/mnt/mmc/MUOS/PortMaster"`, where the real 35 MB install
lives, and it goes on to source `funcs.txt` and `device_info.txt` from there.
A search that stops at the first `control.txt` therefore lands on a directory
with no runtimes and no libs in it. **The redirect must be followed** whenever
the target carries PortMaster payload the holder lacks; the reverse case — a
control.txt rewriting `controlfolder` at a barer directory — must still be
ignored.

**Runtimes — measured.** LOVE 11.5 is present as an *extracted directory* at
`$controlfolder/runtimes/love_11.5/` (`love.aarch64` plus `libs.aarch64/`), not
as a squashfs under `libs/`; `libs/` is empty. There is no Weston runtime, so
the 64-bit path downloads it on first launch. `love.txt` expands
`$controlfolder` and `$DEVICE_ARCH` at source time, so both must be correct
before it is sourced — finding the file by absolute path is not sufficient.

**Console — measured.** There is no framebuffer console. `/proc/consoles` lists
only `ttyS0` (the kernel console is the serial port, `console=ttyS0,115200`),
and the only virtual console is `/sys/class/vtconsole/vtcon0` = `(S) dummy
device`. `/dev/tty1` is writable and **never rendered to the panel**, so a
launcher message written there is invisible. This is the one firmware in the
matrix where the console rung of the message ladder is not available.

**Frontend — measured.** `frontend.sh` is a supervisor loop started by init
(`while :; do … done`), and `muxlaunch`/`muxplore` are its children. Nothing
respawns `frontend.sh`, so **stopping it without restarting it leaves the device
on a black screen until it is rebooted**. Killing only the child is not enough
to hold the panel: the supervisor relaunches it immediately. Every stop must be
paired with `setsid /opt/muos/script/mux/frontend.sh launcher` with the port's
environment unset.

**Graphics — measured.** No `/dev/dri` at all. `/dev/mali0` and `/dev/disp` are
present, so the capability probe must select the `mali` backend — the same
answer as Knulli on the same silicon. `fbset` reports `720x480` visible with a
`720 960` virtual geometry, 32 bpp, `rgba 8/16,8/8,8/0,8/24` (BGRA byte order,
2880-byte stride). The visible height must come from the mode, not from
`virtual_size`.

**Install layout — measured.** The split install works:
`/mnt/mmc/ROMS/Ports/Minecraft Bedrock.sh` alongside
`/mnt/mmc/ports/minecraftbedrock/`, with `/mnt/union/…` unionfs views of both.
The SD card is exfat mounted `fmask=0022,dmask=0022`, so every file already
reads as mode 755 and the launcher never needs an executable bit set.

**Audio — measured.** PipeWire is running with **no Pulse socket at all**
(`/run/pulse` and `/var/run/pulse` are both absent). The native socket is
`/run/pipewire-0` and `PIPEWIRE_RUNTIME_DIR` is unset, which confirms the
reported `PIPEWIRE_RUNTIME_DIR=/run` shape. `/usr/share/pipewire/client.conf`
**is present**, so the dArkOS failure behind FS-6 — PipeWire libraries with no
client config — does not apply here, and OpenAL may be offered PipeWire. The
ALSA PipeWire plugin exists under both `/usr/lib` and `/usr/lib32`.

**ABI — measured.** Both loaders are present (`/lib/ld-linux-aarch64.so.1` and
`/lib/ld-linux-armhf.so.3`), and with no `/dev/dri` the 32-bit client is
correctly unusable, so arm64 is selected.

**Tooling — measured.** `python3` 3.11.8, `timeout`, `nproc`, `flock`, `fbset`,
`unzip`, `pidof`, `setsid`, `killall` are all present, and unlike Knulli
**`readelf` is present**. `weston` and `sway` are absent. ImageMagick
(`convert` 7.1.1) and `fbv` are available, which is what the framebuffer rung of
the message ladder uses.

**Optional Google Play downloader — measured.** muOS meets the prototype's
requirements: aarch64, the `h700` profile, working squashfs loop mounts,
symlink support on the exfat card, and `gptokeyb`/`gptokeyb2` present in
PortMaster. The one thing it lacks is Mesa. Knulli and Batocera get
`mesa_pkg_0.1.squashfs` through PortMaster; muOS ships an empty `libs/`, and
the firmware itself has no Mesa, no Xwayland and no gbm -- only Mali EGL/GLESv2.
Upstream publishes the same package as `mesa_pkg_0.1.aarch64.squashfs`, whose
`lib/aarch64-linux-gnu/libGLX_mesa.so.0` is exactly what the GLX step probes
for, so `ensure_mesa` downloads and verifies it the way `ensure_weston` already
does. Both squashfs images mount cleanly on `/dev/loop0` and `/dev/loop1`, and
`Xwayland` comes from the Weston package at `/tmp/weston/bin/Xwayland`.

muOS also ships **no 64-bit `libcom_err.so.2`** — Knulli does, and only a
32-bit copy exists here under `/usr/lib32`. The sign-in AppImage's
`libgssapi_krb5.so.2` needs it, so the Qt helper exited with "cannot open
shared object file" before drawing anything. The pinned Weston package carries
the library, so `$WESTON_DIR/lib_aarch64` is appended last to every library
path the downloader builds: last, so it fills gaps without shadowing a system
or AppImage library. Weston itself is asked for the `headless noop llvmpipe`
combination on purpose — Crusty presents the frame to Mali directly — so a
headless output in the log is correct rather than a fault.

**Time — measured.** `date` is busybox 1.36.1 and **does not support `%N`**:
`date +%s%3N` returns the literal `1787598189%3N`. The launcher's guard rejects
the non-numeric result and falls back to seconds×1000, so timings are correct
but quantised to one second. Anything that needs sub-second resolution on this
firmware must not be derived from `date`.

**Filesystem — hazard, measured once.** The reference unit's ext4 root was
corrupt: `EXT4-fs error … htree_dirblock_to_tree … Directory block failed
checksum` on the inode for `/usr/lib/python3.11/site-packages`. `readdir` there
returns `EBADMSG`, so every `python3` import that scans `sys.path` fails and the
port cannot install or launch a version. This is a damaged card rather than a
firmware trait, and it is recorded because the port must report it as such
instead of surfacing it later as an unrelated metadata failure.

---


## dArkOS / ArkOS family — no reference device

Covers ArkOS, dArkOS, DarkOS RE and ArkOS-for-clone builds, which share the
layout and display path the port branches on.

**Identity — assumed.** `CFW_NAME` or os-release contains `arkos` (note that
"dArkOS" and "dArkOSRE" both contain the substring), or
`/opt/system/Tools/PortMaster` exists — the path that appears in the issue #1
log.

**Privilege — assumed.** `ESUDO=sudo` on this family, unlike the two measured
firmwares which both set it empty. Nothing may assume `ESUDO` is empty.

**Graphics — from issue #1.** Direct KMSDRM with a real `/dev/dri`.
EmulationStation may still hold DRM master; the launcher logs this. SDL's
KMSDRM backend picks the smallest mode ≥ the requested window, so the panel
mode must be passed explicitly or the client aborts with "Couldn't find any
matching video modes" — the crash in that report.

**ABI — from issue #1.** A 64-bit kernel over an armhf userland. `uname -m`
says `aarch64` while `/usr/lib/arm-linux-gnueabihf/libc.so.6` is what exists,
so ABI selection must ask whether the loader the client requests is present,
not what the kernel is.

**Audio — from issue #1.** PipeWire libraries present without a client config;
OpenAL Soft tries PipeWire, fails to create a context, fails to query RTKit,
and only then reaches ALSA. The triage must not offer PipeWire to OpenAL when
no client config exists.

**Menu input — from issue #1.** `DEVICE_ARCH` is unset, so a gptokeyb target
assembled from it points at a process that never exists.

---

## What would raise these from assumed to measured

- muOS on any H700 device: identity, frontend handoff, the Jacaranda audio
  path, and whether the Wi-Fi startup crash still occurs on 2.0.
- An R36S-class device on dArkOS RE: identity, `ESUDO`, the KMSDRM panel-mode
  fix, the audio triage, and the ABI loader check.

Both correspond to open issues with a reporter attached, so the cheapest route
is the self-test from Phase 4 rather than another round of guessing.
