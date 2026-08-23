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
| muOS | — | — | none |
| dArkOS | — | — | none |

Two firmwares have no reference device. Their contracts are written from the
code and from the two field reports, and are marked accordingly; they are the
ones most likely to be wrong.

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

## muOS — no reference device

**Identity — assumed.** `CFW_NAME` contains `muos`, or `/opt/muos`,
`/mnt/mmc/MUOS` or `/mnt/sdcard/MUOS` exist. Both SD roots must be searched and
`MUOS` is uppercase.

**Frontend — assumed.** muOS owns its framebuffer outside a launched port, so
the port stops `frontend.sh`/`muxlaunch` and restarts through
`/opt/muos/script/mux/frontend.sh launcher` with the port's environment unset.
This is the one firmware where the port manages the frontend itself.

**Install layout — assumed.** Split installs are supported:
`/roms/Ports/Minecraft Bedrock.sh` alongside `/ports/minecraftbedrock/`.

**Audio — reported.** On muOS Jacaranda, PipeWire runs with
`PIPEWIRE_RUNTIME_DIR=/run` and **no** Pulse socket; raw ALSA then fails with
"Device or resource busy" because PipeWire holds the device exclusively. The
triage routes ALSA through the PipeWire plugin via `ALSA_CONFIG_PATH`. Fixed in
v1.4.1 and confirmed by the reporter; not re-verified since.

**Startup network — reported, open.** The same reporter saw the game exit
before the character menu whenever Wi-Fi was on, and reach it every time
offline. Covered by the launcher's offline default for unguarded legacy builds
(FS-1); **unverified on a device**.

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
