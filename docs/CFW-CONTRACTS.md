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

The exception is the case that matters most, because it is the normal one. muOS
starts a port from inside that same loop — the loop calls `launch.sh`, which
calls `ext-general.sh`, which calls the port script — so during a launch
`frontend.sh` is an **ancestor of the port and blocked**, and `muxlaunch` has
already exited. Nothing of the frontend is on the panel, `pidof frontend.sh`
notwithstanding. Stopping it there gains no visibility and costs the port its
own display: the restore starts a second, unrelated `frontend.sh` with `PPid 1`
whose `muxlaunch` draws over the running port and takes its input. Measured on
the reference device while a sign-in window was open. Before touching the
frontend, walk `/proc/<pid>/status` up from the port and leave it alone if
`frontend.sh` is on that chain — muOS returns to its menu by itself when the
port exits. `/proc/<pid>/comm` reads `frontend.sh` for it and `muxlaunch` for
the drawing child, so both are matchable by name.

**Graphics — measured.** No `/dev/dri` **on a pristine device**; `/dev/mali0`
and `/dev/disp` are present, so the capability probe must select the `mali`
backend — the same
answer as Knulli on the same silicon. `fbset` reports `720x480` visible with a
`720 960` virtual geometry, 32 bpp, `rgba 8/16,8/8,8/0,8/24` (BGRA byte order,
2880-byte stride). The visible height must come from the mode, not from
`virtual_size`.

The qualifier matters, because the port creates that node itself. PortMaster's
`westonwrap.sh` runs `mkdir /dev/dri` and `mknod /dev/dri/card0 c 226 0` (lines
202-203 of the pinned pack), so after any run of the optional downloader this
firmware has a `/dev/dri/card0` that no driver is behind — `/sys/class/drm` stays
empty — and it survives until reboot. Audited on the reference device: 31 of the
32 claims in this section verified unchanged, and this was the one that had
drifted.

Nothing broke, because backend selection tries `mali` before `kmsdrm` and this
device has both `/dev/mali0` and `/dev/disp`; a launch made while the synthetic
node existed still resolved `graphics=backend=mali`. What it did do was report
`MCPE_HAS_DRM=1` from a device with no DRM at all. The probe now also requires
the kernel to list the card under `/sys/class/drm`, checked against both
devices on the same day: this one answers 0 with the synthetic node present,
and an RG DS on ROCKNIX — a real `card0` with `card0-DSI-1` and `card0-DSI-2`
— still answers 1.

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

Crusty reads the libraries it wraps from `$CRUSTY_LIBSDL` and `$CRUSTY_LIBEGL`,
and with either unset it symlinks the bare soname into `/tmp/<VARIABLE>64.so` —
a relative target that can never resolve from `/tmp`. westonwrap fills those in
only for its own `crusty*` graphics modes, and this port asks for `llvmpipe`
and preloads Crusty itself, so nothing was setting them. Every SDL pointer in
Crusty therefore stayed null and the sign-in helper died at PC 0 on its first
call, `SDL_SetHint`, inside `glXChooseVisual` during `QGuiApplication` startup.
The port now resolves both with the Weston package's own `tools/findlib`:
`/usr/lib/libSDL2-2.0.so.0` (2.28.5, and it does carry the `mali` video driver)
and `/usr/lib64/libEGL.so.1`. Crusty caches the result as that `/tmp` symlink
and **never replaces an existing one**, so a single failed run poisons every
later run until the device reboots; a stale link is cleared before each start.
Measured on the reference device: with the variables set, `mcpe-signin` maps
`libSDL2` and `libmali`, opens `/dev/mali0`, `/dev/ion` and `/dev/fb0`, and
clears the panel — Crusty's SDL/Mali window is real.

With the window alive, it still drew nothing: QtWebEngine's renderer could not
create its shared-memory file, first in `/dev/shm` — fatal, Chromium calls
`LOG(FATAL)` for that directory by name — and then in `/tmp` once
`--disable-dev-shm-usage` moved it, which is survivable but leaves the page
blank, because software compositing carries the rendered page to the window
through exactly that memory. Both directories are `tmpfs` mode 1777 and the
renderer is uid 0 in the initial mount namespace with `Seccomp: 0` and
`root -> /`; what it does **not** have is capabilities. Measured on the
reference device: `CapEff: 0000000000000000` for a renderer forked from the
zygote, against `0000003fffffffff` for one the browser starts directly under
`--no-zygote` — and with that switch the allocation errors go to zero and
Google's sign-in page renders on the panel. The zygote is only a pre-fork
optimisation here; the sandbox is already disabled, so nothing is lost by
skipping it. This kernel is 4.9 and has **no `CONFIG_USER_NS`** at all
(`/proc/<pid>/ns/user` does not exist), which is worth knowing before reading
anything else about Chromium's sandbox on this firmware.

**A full session — measured.** On 2026-08-25 an RG34XX-SP on muOS 2601.0 signed
in to Google on the device, downloaded the 1.16.221.01 arm64 split set through
the optional downloader, installed it and played. `logs/boot-report.txt`:
`failsafe=rung=0 (tuned) floor=0 pinned=0`, `graphics=backend=mali
compositor=none`, `audio=backend=pipewire alsa=1 pulse=0 pipewire=1`,
`exit_status=0 after 488s (success)`, and the next launch still at rung 0. The
client reported `Mali-G31`, `OpenGL ES 3.2`, its render thread pinned to core 3
with the rest confined to cores 0-1. Controls and sound both worked, reported
by the player at the device. This firmware is therefore measured for behaviour,
not only for capability.

**Controller — measured.** The gamepad is `/dev/input/event1`, named
**`muOS-Keys`** — a `gpio-keys-polled` node, not the `Anbernic RG34XX-SP
Controller` that Knulli exposes for the same hardware. Anything that finds this
device by name therefore finds nothing here, which is what left the Google
sign-in window taking no input at all: it reads evdev directly rather than going
through gptokeyb, because Qt's on-screen keyboard needs in-process navigation
signals that injected key events cannot provide. Match on capability instead —
`BTN_GAMEPAD` plus `ABS_HAT0X`/`ABS_HAT0Y` in the device's own bitmaps.

Neither firmware numbers its buttons semantically (on both, the button at
index 6 is printed *Select*), so the order has to be measured by pressing each
one. Counted from `BTN_GAMEPAD`, on a physical RG34XX-SP:

| Printed | muOS `muOS-Keys` | Knulli `Anbernic RG34XX-SP Controller` |
|---|---|---|
| A / B | 0 / 1 | 0 / 1 |
| X / Y | **3 / 2** | 2 / 3 |
| L / R | **4 / 5** | 10 / 11 |
| Select / Start | 6 / 7 | 6 / 7 |

The D-pad is `ABS_HAT0X`/`ABS_HAT0Y` on both, with -1 up/left and +1
down/right. There are no `ABS_X`/`ABS_Y` axes on this node at all.

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

- muOS: what is left is what needs a player, not another capture. Identity, the
  frontend handoff, graphics, storage and the downloader are measured above on
  the RG34XX-SP reference device; the Jacaranda audio path has been selected
  correctly but never *heard*, and whether the Wi-Fi startup crash still occurs
  on 2.0 needs a real session.
- An R36S-class device on dArkOS RE: identity, `ESUDO`, the KMSDRM panel-mode
  fix, the audio triage, and the ABI loader check. Still nothing measured.

Both correspond to open issues with a reporter attached, so the cheapest route
is the self-test from Phase 4 rather than another round of guessing.
