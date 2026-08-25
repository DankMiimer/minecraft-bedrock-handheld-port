# Coding for muOS

Everything here was measured on the reference **Anbernic RG34XX-SP running muOS
2601.0 JACARANDA** (`BUILD_ID=bc38efa0`) on 2026-08-24 and 2026-08-25, with the
port at v2.0.0-rc.13. It exists because that device is not always available:
when it is gone, this file is what a change to the port has to be written
against. `docs/CFW-CONTRACTS.md` holds the same facts as a contract; this is the
working guide, ordered by what actually cost time.

Re-capture it with `tools/capture-muos.sh` on the device.

## The device

| | |
|---|---|
| SoC / model string | `sun50iw9`, compatible `allwinner,h616` + `arm,sun50iw9p1` |
| Kernel | **4.9.170** aarch64 — no `CONFIG_USER_NS` |
| CPU | 4 cores, `fp asimd aes pmull sha1 sha2 crc32`, governor `ondemand` at rest |
| RAM | 2027140 kB (~1.9 GiB), no swap |
| Panel | `720x480-60`, `geometry 720 480 720 960 32` — the **virtual height is double the visible one** |
| Root | ext4 on `mmcblk0p5`, 7.8 G, read-write |
| SD card | exfat on `mmcblk0p6` at `/mnt/mmc`, plus unionfs at `/mnt/union/ROMS` and `/mnt/union/ports` |
| tmpfs | `/tmp`, `/run`, `/dev/shm` — 989.8 M each |

The model string is the bare SoC name, **not** a product name. Anything that
matches devices by model (`Anbernic RG34XX-SP`, as Knulli reports) will not match
here; match on `compatible` instead.

## Rule 1 — PortMaster is a stub that redirects

`/roms/ports/PortMaster` contains **only** `control.txt`. The real 35 MB install
is at `/mnt/mmc/MUOS/PortMaster`, and the stub's first act is
`export controlfolder="/mnt/mmc/MUOS/PortMaster"`.

Follow that redirect, or every runtime lookup runs against an empty directory and
the port concludes there is no LOVE runtime while `runtimes/love_11.5/` sits
there working. Follow it **only** when the target carries payload the holder
lacks — other CFWs point `controlfolder` at a bare ROMs directory and must not
win.

`libs/` is **empty**. Knulli and Batocera ship Mesa and Weston packages there;
muOS ships nothing, so anything the port needs from `libs/` it has to fetch and
verify itself (see `compat/runtime-index.json`).

`CFW_NAME` is **not** set in a plain shell — PortMaster exports it at launch.
Identity resolution must fall back to `/etc/os-release` (`ID=muos`).

## Rule 2 — nothing you print is visible

`/proc/consoles` lists `ttyS0` only, and the sole vtconsole is `(S) dummy
device`. `/dev/tty1` is writable and goes nowhere. A port that reports a problem
by echoing to the console has told the player nothing: they see a black screen
and a bounce back to the menu.

Order that works: a LOVE frame if the runtime is there, otherwise paint
`/dev/fb0` directly (ImageMagick `convert` and `fbv` are both present). Take the
height from the **visible** geometry reported by `fbset`, not from
`virtual_size` — this panel reports 720x960 virtual for a 720x480 screen.

## Rule 3 — the frontend is a supervisor, and during a launch it is your parent

`frontend.sh` is started by init and nothing respawns it. It runs a loop whose
current child (`muxlaunch` / `muxfrontend` / `muxplore`) is what draws and holds
`/dev/fb0`.

- Killing only the child is useless: the supervisor relaunches it at once.
- Killing the supervisor without starting a replacement leaves the device black
  until reboot.
- **During a port launch, `frontend.sh` is an ancestor of the port** and is
  blocked waiting for it, while `muxlaunch` has already exited. So `pidof
  frontend.sh` returning a pid does not mean a frontend is drawing. Walk `/proc`
  up from your own pid; if you find `frontend.sh` there, leave it alone. Getting
  this wrong starts a second frontend over the running game, which takes the
  input and the panel.

## Rule 4 — the graphics stack is Mali and nothing else

`/dev/mali0`, `/dev/disp` and `/dev/fb0` are present. There is **no** `/dev/dri`
and `/sys/class/drm` is empty. `/usr/lib` has `libEGL`/`libGLESv2` from the Mali
blob; there is **no Mesa** (`/usr/lib/dri` does not exist), **no Xwayland**, **no
weston**, **no sway**.

Two consequences that cost a day each:

- Anything needing GLX under XWayland (the sign-in browser) needs the Mesa
  package downloaded and verified, because `libs/` is empty. Upstream names it
  `mesa_pkg_0.1.aarch64.squashfs`, *not* the `mesa_pkg_0.1.squashfs` that
  Batocera and Knulli install.
- PortMaster's `westonwrap.sh` runs `mkdir /dev/dri` and
  `mknod /dev/dri/card0 c 226 0`. After any run that uses Weston, this firmware
  has a card node **no driver is behind**, and it survives until reboot (a reboot
  clears it — verified). Treat a card node as evidence of DRM only when
  `/sys/class/drm` lists the card too.

## Rule 5 — audio is PipeWire with no Pulse socket

`/run/pipewire-0` exists; `/run/pulse` does not. PipeWire runs as
`pipewire -c /opt/muos/share/conf/pipewire.conf`, and
`/usr/share/pipewire/client.conf` **is** present — which matters, because the
dArkOS failure this port guards against is PipeWire *without* a client config.
`/dev/snd` has `controlC0`–`controlC2` and `pcmC0D0p`.

Settings that produce working sound, confirmed by ear in a real session:
`SDL_AUDIODRIVER=pipewire` with `alsa` as fallback,
`ALSOFT_DRIVERS=pipewire,pulse,alsa`, and `ALSA_CONFIG_PATH` pointed at a config
routing `default`/`sysdefault` through the PipeWire plugin.

## Rule 6 — the gamepad is `muOS-Keys`, and the buttons are not where you think

| node | name | phys |
|---|---|---|
| `event0` | `axp2202-pek` | `m1kbd/input2` |
| `event1` | **`muOS-Keys`** | `gpio-keys-polled/input0` |
| `event2` | `dierct-keys-polled` | `dierct-keys-polled/input0` |

`/dev/input/js0` exists. Knulli calls the same hardware `Anbernic RG34XX-SP
Controller`, so matching on that name finds nothing here. Match on capability
(`BTN_GAMEPAD` plus the D-pad hat), with names as hints only.

Button indices counted from `BTN_GAMEPAD`, measured by pressing every printed
button on both firmwares:

| Printed | muOS `muOS-Keys` | Knulli `Anbernic RG34XX-SP Controller` |
|---|---|---|
| A / B | 0 / 1 | 0 / 1 |
| X / Y | **3 / 2** | 2 / 3 |
| L / R | **4 / 5** | 10 / 11 |
| Select / Start | 6 / 7 | 6 / 7 |

Neither firmware numbers them semantically — on both, index 6 is printed
*Select*. Do not derive these; measure them.

## Rule 7 — both ABIs are present, but one library is not

`/lib/ld-linux-aarch64.so.1` and `/lib/ld-linux-armhf.so.3` (a symlink into
`/usr/lib32`) both exist, so 64-bit and 32-bit payloads can run.

`libcom_err.so.2` exists **only** as a 32-bit copy under `/usr/lib32`. Anything
64-bit that pulls in `libgssapi_krb5.so.2` — the sign-in AppImage does — needs a
64-bit copy supplied. The pinned Weston package carries one; append that
directory **last** on the library path so it can only fill a gap and never
shadow a system library.

SDL2 is `2.28.5` at `/usr/lib/libSDL2-2.0.so.0`, and it does carry the `mali`
video driver.

## Rule 8 — busybox, and what it cannot do

Everything is busybox 1.36.1, a **static** binary at `/bin/busybox`.

| Present | Missing |
|---|---|
| `python3` (3.11.8), `timeout`, `nproc`, `flock`, `fbset`, `unzip`, `readelf`, `pidof`, `setsid`, `killall`, `convert`, `fbv`, `curl`, `strings` | `gdb`, `Xwayland`, `weston`, `sway`, Mesa |

Note `nproc` **is** here — ROCKNIX is the firmware that lacks it.

Two busybox limits that break otherwise-portable code:

- **`tar` has no `-z`.** `tar czf` fails with `invalid option -- 'z'`. Pipe
  through gzip instead: `tar cf - dir | gzip > out.tar.gz`.
- **`date` has no `%N`.** `date +%s%3N` returns the literal `1787655168%3N`, so
  every millisecond timing degrades to whole seconds. Guard for it rather than
  trusting the output.

## Rule 9 — do not assume busybox regex works

On 2026-08-25 this unit's busybox began **crashing with SIGILL on every regex
path**, 100% reproducibly:

```
$ printf 'a 1\n' | awk '/a/{print $2}'
Illegal instruction        (exit 132)
$ awk 'BEGIN{ if ("abc" ~ /b/) print "match" }'
Illegal instruction        (exit 132)
$ pgrep -f something
Illegal instruction        (exit 132)
```

while non-regex use of the same binary is fine:

```
$ printf 'a 1\n' | awk '{print $2}'               -> 1
$ printf 'a 1\n' | awk 'index($0,"a"){print $2}'  -> 1
$ printf 'a 1\n' | grep -E '^a'                   -> a 1
$ printf 'a 1\n' | sed -n 's/^a //p'              -> 1
```

What is known: the binary is static, its md5 is stable across reads
(`05065fb84dceea88aeb5d7814095c8bf`), `/etc/ld.so.preload` does not exist, a
clean `env -i` still crashes, the kernel log shows no EXT4 error and no trap, and
the same expressions **worked earlier the same day**, before a reboot. This unit
had ext4 corruption repaired in an earlier session, so silently corrupt bytes in
the regex region of that binary is the leading explanation — it is not proven,
and it has not been seen on any other muOS device.

Treat it as a **device state, not a firmware property**. The lesson that
generalises is cheap to apply anyway: on the launch path prefer `grep`, `sed`,
`case` and shell parameter expansion over `awk '/re/'` and `pgrep`, so a broken
regex engine degrades instead of failing. The port launched and played normally
in this state, because its regex uses sit in memory detection, panel geometry and
the ancestry walk, and all of them fall back.

## Rule 10 — paths, in one place

```
/roms/ports/PortMaster/control.txt      stub, redirects to the line below
/mnt/mmc/MUOS/PortMaster                the real PortMaster (runtimes/love_11.5)
/mnt/mmc/ROMS/Ports                     where a port archive extracts
/mnt/union/ROMS/Ports                   the same tree through unionfs; what a
                                        launched port sees as its own directory
/roms/ports                             a third view of the same tree
/mnt/mmc/ports/<port>                   this port's code
/mnt/mmc/ports/<port>-data              shared data: APKs, versions, profiles
/opt/muos/script/mux/frontend.sh        the frontend supervisor
/opt/muos/frontend/muxfrontend          the binary that draws
```

`profiles` inside the port directory is a **symlink** into the `-data`
directory, which is why a port update replaces code without touching worlds.

## Reproducing these measurements

`tools/capture-muos.sh` dumps every fact above in one pass. Run it on the device
and keep the output beside a device report:

```
sh tools/capture-muos.sh > muos-capture.txt
```
