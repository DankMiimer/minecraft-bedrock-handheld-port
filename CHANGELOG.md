# Changelog

## v2.0.0-rc.14 (testing)

Robustness, from a week on real hardware. Two capability answers the port was
getting wrong on muOS -- a DRM node with no driver behind it, and four launch
lookups that needed a working regex engine -- plus the muOS reference guide,
written while the device was still available to check against. No gameplay
change from rc.13.

- **The launch path no longer needs busybox's regex engine.** Memory size,
  panel geometry and the frontend-ancestry walk went through `awk '/re/'`, and
  Weston cleanup through `pkill -f`. On the muOS reference device every busybox
  regex path began dying with SIGILL, and the visible result was a boot report
  reading `memory_kb=0` with `memory_tier=unknown`, plus `wp_weston` and the
  client left running after the game exited. All three lookups now read the file
  in-shell (`mcpe_meminfo_kb`, `mcpe_proc_ppid`, `mcpe_fb_geometry` in
  `lib/common.sh`), and the Weston kill tries name-matching `killall` before the
  regex `pkill`. Verified on that device with its `awk` still crashing: memory
  reads 2027140 kB where it read 0. A contract test keeps these lookups
  regex-free.

- **`docs/CODING-FOR-MUOS.md`, and `tools/capture-muos.sh` that produces it.**
  Ten rules for changing this port against a firmware nobody may have to hand,
  each backed by a measurement from the RG34XX-SP reference device rather than
  by recollection: the PortMaster stub redirect, the invisible console, the
  frontend supervisor that becomes your own ancestor during a launch, the
  Mali-only graphics stack and the card node westonwrap leaves behind, PipeWire
  with no Pulse socket, the `muOS-Keys` gamepad and its measured button order,
  the missing 64-bit `libcom_err.so.2`, and what busybox cannot do (`tar -z`,
  `date +%N`). Written on the day the device was about to be handed back to
  Knulli, so the facts survive the hardware going away.

- **A `/dev/dri/card0` that no driver is behind no longer counts as DRM.**
  PortMaster's `westonwrap.sh` runs `mknod /dev/dri/card0 c 226 0` on firmwares
  that have no DRM at all, and the node outlives the run, so after one use of
  the optional downloader a muOS device reported `MCPE_HAS_DRM=1` while
  `/sys/class/drm` stayed empty. The capability probe now requires the kernel to
  list the card as well. Measured on both reference devices the same day: muOS
  answers 0 with the synthetic node present, and an RG DS on ROCKNIX with a real
  `card0` and two connected DSI connectors still answers 1. No backend changed —
  `mali` is chosen before `kmsdrm` and muOS has `/dev/disp` — but the reported
  flag is now true, and a firmware without mali could have been pushed onto the
  wrong backend by a leftover node.

## v2.0.0-rc.13 (testing)

Diagnostics, not gameplay: rc.12's self test reported a runtime as missing on
the firmware that downloads it for itself, and five of the contract tests
guarding this month's muOS work turned out never to have executed. The port
itself is unchanged from rc.12.

- **The self test told muOS players a runtime was missing when it was mounted.**
  It looked for the Weston package only in PortMaster's own `libs/` and
  `runtimes/` — where Knulli and Batocera install it — and never in the port's
  own `runtime/` directory, which is where `ensure_runtime.sh` puts it when
  PortMaster does not carry it. On muOS that warning could never clear. Found by
  running the self test on a device that had just downloaded, verified and
  mounted the package. The report now reads 17 ok, 1 warning, 0 failures there.

- **Five CFW contract tests had never run.** `tests/test_cfw_contracts.py`
  collects its tests out of `globals()` from an `if __name__ == "__main__"`
  block, and five tests had been appended *after* that block, so they did not
  exist yet when it executed — including the muOS PortMaster redirect, the
  message ladder, the frontend pairing rule and the downloader gate parity. The
  runner moved to the end of the file, with a comment saying why it has to stay
  there. All fifteen pass; verified by mutation that the previously skipped ones
  now really execute.

## v2.0.0-rc.12 (testing)

muOS becomes a firmware this port is measured on for behaviour, not only for
capability. An RG34XX-SP running muOS 2601.0 JACARANDA now signs in to Google
on the device, downloads a Bedrock build, installs it and plays, with working
controls and sound. Everything below in this release came out of getting there.

- **Minecraft Bedrock now runs on muOS, start to finish, with no PC involved.**
  On 2026-08-25 an RG34XX-SP running muOS 2601.0 JACARANDA signed in to Google
  on the device, downloaded the 1.16.221.01 arm64 split set, installed it and
  played, with working controls and sound. The session ran at failsafe rung 0
  with performance mode active and exited cleanly after 488 seconds. muOS is now
  a firmware this port is *measured* on for behaviour, not only for capability,
  and the README tells players the on-device route exists.

  Every fault between the muOS tile and that session is fixed, and each is
  listed separately below: the PortMaster stub redirect, the launcher message no
  console rendered, the downloader gate and its missing Mesa package, the absent
  `libcom_err.so.2`, the SDL library Crusty never resolved, the sign-in
  browser's renderer capabilities, the second frontend the message ladder
  started over the running port, and the controller the sign-in window could not
  find.

- **The muOS sign-in window took no input.** The page rendered and the buttons
  did nothing. The helper reads the gamepad straight from `/dev/input` — it has
  to, because Qt's on-screen keyboard needs in-process navigation signals that
  injected key events cannot provide — but it found that gamepad by *name*, and
  the name it looked for is Knulli's `Anbernic RG34XX-SP Controller`. muOS calls
  the identical hardware `muOS-Keys`, so no device was ever opened.

  It now prefers that name and otherwise takes any device that reports what it
  actually reads: the gamepad buttons and the D-pad hat. The button order had to
  be measured rather than derived — neither firmware numbers its buttons
  semantically, and on muOS X and Y are swapped and the shoulders sit at 4 and 5
  instead of 10 and 11 — so both layouts are now recorded in the helper and in
  the CFW contract, each one captured by pressing every printed button on the
  hardware. The chosen device is named in the private sign-in log, so the next
  firmware can be told apart from one whose buttons are merely mapped wrongly.

- **On muOS, a second frontend appeared on top of the running port.** Any
  launcher message drew it: the message ladder stops muOS's frontend before
  drawing, and `pidof frontend.sh` matches even when that supervisor is the
  port's own blocked ancestor — muOS starts ports from inside its frontend
  loop, so `frontend.sh` is alive but waiting and `muxlaunch` is not running at
  all. The ladder killed the ancestor, drew the message, and then "restored"
  the frontend by starting a fresh one, which promptly drew over the port and
  took its input. The player saw it beside the Google sign-in window, with the
  sign-in page visible but only the muOS menu responding.

  The ladder now walks up `/proc` first and leaves a `frontend.sh` that
  launched this port alone; nothing of it is on the panel while it waits, and
  muOS returns to its own menu when the port exits. A frontend that really is
  drawing — a port started over SSH or from a shell — is still stopped and
  restored exactly as before.

- **The muOS sign-in window came up black.** With the helper finally alive, Qt
  rendered frames and swapped them, and the page inside stayed empty:
  QtWebEngine's renderer could not create its shared-memory file. In `/dev/shm`
  that is fatal — Chromium calls `LOG(FATAL)` for that directory by name — and
  in `/tmp` it is survivable but blank, because software compositing is how a
  rendered page reaches the window. Both directories are `tmpfs` mode 1777 and
  the renderer runs as uid 0 with no seccomp filter and no chroot; what it does
  not have is capabilities. A renderer forked from Chromium's zygote reports
  `CapEff: 0000000000000000`, against `0000003fffffffff` for one the browser
  starts directly.

  The port now passes `--no-zygote` (and keeps `--disable-dev-shm-usage`, so
  that a future child which does lose its capabilities degrades instead of
  aborting). The zygote is only a pre-fork optimisation here — the sandbox is
  already disabled for this window — so nothing is lost by skipping it. On the
  muOS reference device the allocation errors go to zero and **Google's sign-in
  page renders on the panel**, confirmed by eye on the hardware.

- **The muOS sign-in window crashed the moment Qt asked for OpenGL.** Past the
  missing `libcom_err.so.2`, `mcpe-signin` died at PC 0 inside
  `glXChooseVisual` — a call through a null pointer, on its first use of SDL.
  Crusty reads the libraries it wraps from `$CRUSTY_LIBSDL` and `$CRUSTY_LIBEGL`,
  and with either unset it symlinks the bare soname into `/tmp/<VARIABLE>64.so`,
  a relative target that can never resolve from `/tmp`. westonwrap fills those
  in only for its own `crusty*` graphics modes, and the port asks for `llvmpipe`
  and preloads Crusty itself, so nothing was setting them and every SDL entry
  point stayed null.

  `run.sh` now resolves both with the Weston package's own `tools/findlib`
  (falling back to the usual library directories) and hands them to the session.
  Crusty caches the result as that `/tmp` symlink and never replaces an existing
  one, so one failed run used to poison every later run until the device
  rebooted; a stale link is now cleared before each start. Measured on the muOS
  reference device: the helper survives startup, maps `libSDL2` and `libmali`,
  and opens `/dev/mali0` and `/dev/fb0` — Crusty's SDL/Mali window is real.

- **The muOS sign-in window died before it drew anything.** With the tile finally
  reachable, `mcpe-signin` exited immediately:
  `error while loading shared libraries: libcom_err.so.2`. muOS ships no 64-bit
  copy of that library — Knulli does, and muOS has only a 32-bit one under
  `/usr/lib32` — while the sign-in AppImage's `libgssapi_krb5.so.2` needs it.
  The pinned Weston package already carries the right one, so
  `$WESTON_DIR/lib_aarch64` is now appended to every library path the downloader
  builds. It goes **last** deliberately: it fills a genuine gap without being
  able to shadow a system or AppImage library. Measured on the device, the
  helper went from two unresolved libraries to none.

  For the record, the `Output 'headless'` line in `downloader.log` is not a
  fault. `run.sh` asks Weston for `headless noop kiosk llvmpipe` on purpose and
  Crusty presents the frame to Mali directly, so a headless output is what a
  healthy run looks like.

- **The Google Play downloader now runs on muOS.** It was gated to Knulli and
  Batocera, and behind that gate sat a real dependency rather than an arbitrary
  restriction: the Qt WebEngine sign-in window needs Mesa to provide GLX to
  XWayland, and `ensure_mesa` only ever looked for `mesa_pkg_0.1.squashfs` in
  PortMaster's `libs/`. That is the filename Batocera and Knulli install
  locally. muOS ships an empty `libs/`, and the firmware itself has no Mesa, no
  Xwayland and no gbm — only Mali EGL/GLESv2 — so the package was genuinely
  absent rather than merely misnamed.

  Upstream publishes it as `mesa_pkg_0.1.aarch64.squashfs`, which the port had
  never asked for. Its `lib/aarch64-linux-gnu/libGLX_mesa.so.0` is exactly the
  file the GLX step probes for, so it is now pinned in
  `compat/runtime-index.json` by SHA-256 and size and fetched by
  `ensure_runtime.sh` — the same verified path the Weston package already uses,
  from the same host, so the downloader's network allowlist is unchanged and
  `scripts/check_downloader_policy.py` still passes.

  Measured on an RG34XX-SP running muOS 2601.0 JACARANDA: both squashfs images
  mount on loop devices, `libGLX_mesa.so.0` resolves, the GL bridge links, and
  `Xwayland` comes from the Weston package. The gate now reads the firmware the
  launcher already resolved (`MCPE_CFW`) instead of re-grepping `os-release`,
  and falls back to reading the firmware directly when the downloader is run
  without the launcher in front of it.

- **muOS is a reference device now, and the port could not start on it.** An
  RG34XX-SP running muOS 2601.0 (JACARANDA) — the same hardware as the Knulli
  reference, so the pair is a controlled comparison — showed the port opening to
  a black screen and dropping back to the menu. Nothing had crashed. Two
  separate faults stacked into one dead end:

  - **PortMaster resolved to a stub.** On muOS `/roms/ports/PortMaster` holds
    `control.txt` and nothing else; its first act is to point `controlfolder` at
    the real 35 MB install under `/mnt/mmc/MUOS/PortMaster`. The launcher threw
    that redirect away — the line existed to stop *other* CFWs rewriting
    `controlfolder` at a bare ROMs directory — so every later lookup ran against
    a directory with no runtimes in it. The LOVE menu was reported missing while
    `runtimes/love_11.5/love.aarch64` sat there working, which meant the one
    route a player has to install an APK was gone. The redirect is now followed
    when, and only when, the target carries PortMaster payload the holder lacks.
  - **The message saying so was invisible.** `show_msg` writes to `/dev/tty1`.
    muOS binds no framebuffer console: `/proc/consoles` lists only `ttyS0` and
    the sole vtconsole is `(S) dummy device`, so `/dev/tty1` is writable and
    never reaches the panel. "No Minecraft version installed. Copy your own APK
    into…" was printed correctly and shown to nobody.

  `show_msg` is now a ladder. The console keeps first place wherever it is
  really rendered, so both existing reference devices are on the path they were
  verified on. Where it is not rendered the launcher draws a LOVE frame, and
  failing that paints `/dev/fb0` directly using ImageMagick and the port's own
  font, which depends on no runtime at all (FS-11). Stopping the muOS frontend
  to draw is always paired with restarting it: `frontend.sh` is a supervisor
  started by init that nothing respawns, so an unpaired stop leaves the device
  black until it is rebooted.

- **A broken interpreter now says it is broken.** The reference unit's ext4 root
  is corrupt — `EXT4-fs error … Directory block failed checksum` on the inode
  for `/usr/lib/python3.11/site-packages` — so `readdir` there returns EBADMSG
  and every `python3` import that scans `sys.path` fails. The port needs Python
  to install an APK and to resolve a version, so this is fatal, but it used to
  surface much later as "Legacy version metadata backfill failed". The launcher
  and the self test now check the interpreter up front and name the cause,
  pointing at `e2fsck` and the kernel log rather than at the port.

- **Two stderr captures fed `eval`.** `version_env.py` and `release_select.py`
  were captured with `2>&1` and evaluated. muOS's Python writes a
  `sitecustomize` warning on every run while still exiting 0, so the noise
  became shell: measured, the assignments still landed but four "not found"
  errors were printed and `$@` was clobbered. Both now keep the streams apart
  and read stderr only when the interpreter actually failed.

- **The muOS platform fixture was wrong where it mattered.** It had been
  constructed rather than captured, and gave the device `/dev/dri` and the
  `kmsdrm` backend. The hardware exposes no DRM node at all and correctly
  resolves to `mali`; it also reports its model as the bare SoC string
  `sun50iw9` rather than a product name, which is why the `h700` profile has to
  match on the compatible. Replaced with the captured values, and
  `docs/CFW-CONTRACTS.md` promotes the muOS contract from assumed to measured —
  including that muOS *does* ship `/usr/share/pipewire/client.conf`, so the
  dArkOS cause behind FS-6 does not apply there.

  Two things the capture did **not** establish, recorded in `docs/FAILSAFES.md`
  so nobody reads more into it: no rung of the failsafe ladder ran in a real
  session, because that unit cannot launch the game at all; and busybox `date`
  has no `%N`, so `date +%s%3N` returns a literal `1787598189%3N` and every
  millisecond timing on muOS is quantised to one second.

- **`mcpe_pipewire_client_usable` now honours `MCPE_PROBE_ROOT`.** Its fallback
  paths answered for the build host, so on any machine with PipeWire installed —
  muOS among them — the negative case could never be observed and
  `tests/test_audio.sh` failed. Behaviour on a device is unchanged.

- **The frame cap is now keyed to the game version, and 40 is gone.** Bedrock
  1.16.221.01 and older default to 50 fps, everything newer to 30. The cap the
  port shipped was the worst value available on the RG34XX-SP's 59.156 Hz
  panel. Even with VSync off the panel only swaps on a refresh boundary, so
  what reaches the eye is the whole number of refresh intervals each frame is
  held for; a cap landing between two multiples turns every frame into a coin
  flip between them. Measured on the reference device, superflat, stationary,
  ~16k frames per window:

  | cap | achieved | frame time | intervals | holds | hold stdev | jitter |
  | --- | --- | --- | --- | --- | --- | --- |
  | 60 | 57.5 fps | 17.38 ms | 1.03 | 1x94% 2x6% | 0.24 | 2.61 ms |
  | 50 | 47.0 fps | 21.29 ms | 1.26 | 1x74% 2x26% | 0.44 | 2.48 ms |
  | 40 | 37.9 fps | 26.41 ms | 1.56 | 1x44% 2x56% | 0.50 | 3.31 ms |
  | 30 | 29.0 fps | 34.48 ms | 2.04 | 2x92% | 0.29 | 2.30 ms |

  40 sat almost exactly halfway between one and two refreshes, doubling the
  hold spread and raising frame-to-frame jitter 44% against 30. p99 stayed
  inside each cap's own interval in all three windows, so these are limiter
  cadence differences, not dropped frames; every cap also came in 4-5% under
  target, which is limiter overhead. 30 is also the cap that stays *binding*,
  and therefore evenly paced, once load rises past what superflat asks for --
  60 only looks good here because this scene lets the device hit it. Older
  builds render cheaply enough to hold a higher cap, and 50 trades evenness for
  responsiveness: it buys 18 fps over 30 for a 74/26 hold split instead of 92%
  steady, while its frame-to-frame jitter is the second lowest of the four
  (2.48 ms against 30's 2.30 ms and 40's 3.31 ms) -- the renderer is steady, it
  is the scanout cadence that is not. This panel has no clean divisor between
  29.6 and 59.2, so that trade is unavoidable at this frame rate.

  Re-measured in a generated world at the shipped 80-block render distance, to
  check the superflat result was not an artefact of an unusually light scene.
  It was not -- 50 gives 46.2 fps at 1.28 intervals (73/27, hold stdev 0.44)
  and 30 gives 28.9 fps at 2.04 intervals (91% steady, hold stdev 0.30), both
  within noise of the superflat pair. The cap stops mattering only once the
  scene outruns it: at 192 blocks the same world is GPU-bound at 32 fps and
  lands on 1.85 intervals whatever the cap says. The player's
  own FPS cap setting still wins over both defaults, and armhf/R36S keeps its
  throughput-bound 10.
- The port now **measures how much memory the device has** and tells the game.
  Four tiers -- 512 MB, 1 GB, 2 GB, 3 GB -- chosen from `MemTotal`, with the
  boundaries between the fittings rather than on them, because the kernel only
  counts what the firmware's carveouts leave behind: the reference RG34XX-SP
  reports 1980 MB for its 2 GB, and the R36S about 500 for its 512. The tier
  sizes the texture streaming budget (`gfx_max_dequeued_textures_per_frame`,
  2/8/16/16) and, on 3 GB, the render distance. The 2 GB row is exactly what
  the port already shipped, since that is the device the profile was validated
  on; 80 blocks stays the floor on the smaller tiers because Bedrock clamps any
  request below it straight back up.
- The client no longer answers every Android memory question with physical RAM.
  `getMemoryLimit` now reports `MCPE_GAME_MEMORY_BUDGET_MB` -- the machine less
  what the firmware, the frontend, Weston and the launcher already hold -- and
  `getFreeMemory` reports `MemAvailable` instead of `sysinfo()`'s `freeram`.
  The old answer was factually wrong: Linux keeps every idle page in the page
  cache, so `freeram` is not "memory the game may have". On the reference
  device, idle with the frontend resident, freeram reads 484 MB against a
  MemAvailable of 1643 MB of 1979 MB total; in a loaded world it reads **33 MB
  against 1078 MB available**. Bedrock was being told it had 33 MB left on a
  device with a gigabyte free.

  **It did not cost frames, though -- measured, not assumed.** A/B on the
  reference RG34XX-SP, same world and spot, 192-block render distance, 85s
  in-world windows on each client: 32.0 fps new against 31.9 fps old, 0.00%
  stutter frames and zero major faults on *both*. The old client was fed the
  33 MB figure and simply did not act on it. Peak RSS was 632 MB, which never
  approaches either limit (1584 MB new, 1979 MB old), so `getMemoryLimit` does
  not bind on a 2 GB device either.

  The change is kept because reporting 33 MB when 1078 MB is available is
  wrong regardless, and because the numbers suggest where it *would* bind: a
  1 GB device gets a ~640 MB budget, right at the 632 MB working set measured
  here. That case is untested -- there is no 1 GB reference device in this
  tree. **Needs a client rebuild to take effect**; the shell-side tiers do not.
- Fixed: the one-time arm64 preset overwrote the explicit pins on the launch
  that seeded a profile. `tune_game_options` documents two tiers -- pins always
  win, guardrails only edit keys the game already wrote -- but wrote the pins
  first, so the preset file's own `gfx_viewdistance`, `gfx_max_framerate` and
  `gfx_vsync` landed on top of them. Demonstrated on the reference device:
  `MCPE_RENDER_DISTANCE=96` produced `gfx_viewdistance:80` on a fresh profile.
  It was invisible while every device was pinned to the preset's own values and
  became visible the moment the memory tier gave devices different ones.

- The startup watchdog no longer costs a frame's worth of work every second.
  It never disarms unless frame metrics are on -- which they are not by default
  -- so its tick ran for the whole session, and the tick spawned four processes
  (`cat`, `awk`, and `wc` twice) to read two numbers. Reading `/proc/pid/stat`
  in the shell and detecting log growth with an mtime sentinel does the same
  job with no process at all.

  Re-measured on the reference RG34XX-SP, 500 ticks of each against a 400 KB
  log, frontend resident, governor on schedutil:

  | | wall | cpu | `execve` | `clone` |
  | --- | --- | --- | --- | --- |
  | old tick | 28.8 ms | 2.46 ms | 5 (bash, cat, awk, wc, wc) | 6 |
  | new tick | 0.61 ms | 0.60 ms | 1 (bash) | 0 |

  Roughly a 47x cut in wall time, against 25 ms per rendered frame. An earlier
  pass recorded 21.1 ms against 0.45 ms without stating its log size; the ratio
  reproduces exactly but the absolute numbers do not, and `wc -c` scales with
  the log, which is the likely difference. Behaviour is unchanged, and the same
  tests pass against both versions.
- The shutdown watchdog greps the client log once every two seconds rather than
  every second. Bounding the read with `tail -c` was tried and measured no
  better (5.4 ms against 5.3 ms on a 420 KB log) because the second process
  costs more than the skipped read saves; the period is the part that helps.
- `tests/test_watchdog.sh` builds its fake client from `bash` rather than
  `/bin/sleep`. On every firmware this port targets `/bin/sleep` is a symlink
  into a multi-call `coreutils` binary, which refuses to run under an argv[0]
  it does not recognise, so the fixture exited instantly and every case in the
  file failed on the reference device.

- A **UI zoom** setting makes 1.21.51.01 usable on a small panel. Measurements
  on the reference RG34XX-SP show that build takes its UI scale from the real
  render surface alone: the client `scale` setting, `MCPE_REPORTED_DISPLAY_SCALE`,
  `gfx_guiscale_offset`, `gfx_pixeldensity`, `gfx_resizableui` and the
  `upscaling_*` keys all leave the rendered UI pixel-identical, because 1.21
  never asks for the reported DPI at all. Rendering at two thirds of the panel
  and letting the display scaler enlarge it gives a 1.5x larger UI for 55%
  fewer pixels, and is now one row in the launcher menu with a gentler 1.25x
  step beside it. `docs/UI-SCALING.md` records the matrix and the method.
- The smaller-than-native framebuffer path no longer trusts `fbset`. It
  reported success for 600x400 and 360x240, which do not survive a session on
  this graphics stack, so the port claimed a mode it was not running and would
  have restored one it never set. Sizes must now be multiples of 16, which is
  what separates the modes that hold from the ones that do not, and the
  geometry is read back before the mode is believed.
- The **UI scale** row now says it applies to 1.16 only, rather than silently
  doing nothing on the newer build.
- **menu+L3** takes a screenshot while the game runs, written as a PNG to
  `ports/minecraftbedrock/screenshots/`. There is no compositor screenshot key
  on the framebuffer path, so a small watcher reads the evdev nodes alongside
  the client. Pads whose printed labels do not match the `BTN_` names their
  driver sends get a layout entry: on the RG34XX-SP the labels sit one place
  off, L3 arrives as `0x139`, and one press of MENU emits both `0x138` and
  `0x162`, so a chord named after the kernel would have watched for buttons
  that pad never sends. Confirmed on the device. Override the chord with
  `MCPE_SCREENSHOT_COMBO=menu+r3`, name new hardware with
  `MCPE_SCREENSHOT_DEBUG=1`, disable with `MCPE_SCREENSHOTS=0`.

## v2.0.0-rc.11 (testing)

Cross-firmware reliability work. Knulli and ROCKNIX were verified on reference
devices; muOS and the ArkOS family remain unmeasured, which the new self test
exists to change.

- The port now resolves which firmware it is on in one place instead of four
  drifting copies, and ROCKNIX and the ArkOS family have an identity for the
  first time. Knulli reports `NAME=Batocera.linux` and announces itself only in
  `OS_NAME`, so the resolver matches across all os-release fields at once.
- Every launch records the stage it reached, overwritten in place so it
  survives a hard power-off. After a freeze, the next launch reports where the
  previous one stopped -- the information missing from issue #2, whose log
  field is empty because the log is truncated on every start.
- A startup watchdog supervises the launch from client exec. If the client
  stops making progress it writes `logs/hang-report.txt` with process and
  thread state, terminates it, and restores the frontend, instead of leaving a
  device that needs a power cycle. It detects a stall rather than enforcing a
  deadline, so a slow first launch on a cold card is not killed.
- A failsafe ladder drops to a conservative launch profile when a launch fails
  to start and climbs back after two clean ones. Every rung above the tuned
  profile is announced on screen with a way to overrule it, and
  `docs/FAILSAFES.md` records what each failsafe costs and the evidence needed
  to remove it. Pin it with `safe_mode` in the launcher menu.
- Old Bedrock builds that exit before the character menu when Wi-Fi is on are
  now covered by the launcher. The in-client guard is compiled out on armhf and
  pinned to one arm64 binary, and the compatibility registry claimed it for
  three combinations where it cannot fire; the registry is corrected and the
  launcher fills the gap. `Network / LAN` in the menu overrides it.
- Both launch paths share one audio backend selection. The 32-bit path
  previously set none, so OpenAL tried PipeWire first and failed twice on
  dArkOS images that ship the libraries without a client config (issue #1).
- ABI selection asks whether the loader the client requests exists, rather than
  trusting `uname`: dArkOS RE runs a 64-bit kernel over an armhf userland.
- New **Self test** in the launcher menu, and `selftest.sh` over SSH. It checks
  the device without starting Minecraft or needing an APK and prints a short
  redacted report for a bug report.
- Support bundles no longer destroy Bedrock version numbers. They are shaped
  like IPv4 addresses, so the address filter had been rewriting `1.16.221.01`
  to `REDACTED_IP` and deleting the most useful field in every bundle.
- The bug report template asks for the self test, the firmware, and how far the
  launch got; `TESTING.md` gains a per-firmware acceptance checklist.

## v2.0.0-rc.10 (testing)

- Extended the policy checks to the Windows/Linux helper, so both downloaders
  are now held to the same three rules by the same script. The helper carries
  its own `tools/mcbedrock-get/PROVENANCE.json` -- what it builds from source
  and from which revision, which requirement files must stay pinned, which
  files hold account data and which module clears each one, and every host it
  may contact -- and that manifest now ships inside the Windows bundle, beside
  the executable it describes.

- Pinned the Play client the helper builds. `setup-downloader.sh` cloned
  whatever the upstream default branch happened to be that day and pulled it
  forward on every rerun, so nobody -- including the user -- could say
  afterwards which source produced the binary they ran. It now fetches and
  checks out the same commit the port's own ARM64 gplaydl is built from, and
  the checker fails on a `git pull`, a `--branch`, or an unpinned shallow
  clone. The pinned revision was built end to end on Ubuntu 24.04.3 under WSL2
  to confirm it still compiles: both tools build, install, and refuse to run
  without a session, with only upstream's libcurl deprecation warnings.

- Made the helper write the saved Google account token owner-only. It was
  created at the default mode, which on Linux means a live token readable by
  every other account on the machine; it is now created `0600` from the first
  byte inside a `0700` directory, on both platforms.

- Wrote down the three rules the on-device Google Play downloader lives by --
  strictly open source, no hardcoded workaround for Play's ownership check, and
  no user credential on or through a third party -- and made them enforceable
  rather than aspirational. `DOWNLOADER-POLICY.md` states each rule, how the
  downloader satisfies it, and the two gaps that remain open (build
  reproducibility and the disabled Qt WebEngine sandbox).
  `scripts/check_downloader_policy.py` re-checks all three on every push, and
  `tests/test_downloader_policy.py` breaks a synthetic downloader twenty-odd
  ways to prove the checker actually catches violations.

- Gave the downloader two manifests the checker holds it to. `PROVENANCE.json`
  records every shipped binary with its SHA-256, size, upstream commit or
  in-repo source, licence text and build script, alongside the pinned optional
  downloads and the complete list of hosts the downloader may contact -- only
  Google's own endpoints may see account data. An undeclared or rebuilt binary,
  a drifted runtime pin, or a new hostname now fails the build.
  `credential-artifacts.txt` names every path that can hold account data, and
  `run.sh` reads that same file to decide what to delete, so sign-out and the
  policy check cannot drift apart.

- Closed three credential-hygiene gaps found while writing that policy: a
  cancelled or interrupted sign-in no longer leaves Google's one-shot token on
  the card, sign-out now clears the sign-in capture, exchange input and Qt
  diagnostic logs it previously left behind, and the support bundle's redaction
  filter now covers spaced `user_token = ...` assignments, `CRED=`/`CREDB64=`
  lines, Google token prefixes and email addresses before a log can be attached
  to a public issue.

- Fixed the untested-build confirmation never appearing after upgrading from
  rc.8. The menu's list of installable APK sets is cached against the state of
  the APK files, and upgrading the port does not change those, so rc.9's new
  "untested" column was missing from every index that already existed.
  Choosing such a build failed with "choose it again to confirm", and choosing
  it again did the same thing. APK sets downloaded after the upgrade were never
  affected. Found by upgrading a real RG34XXSP from rc.8.

## v2.0.0-rc.9 (testing)

- Builds outside the tested 1.16-1.21 range can now be installed after
  confirming, instead of being refused outright. The version browser offers
  every build Google Play still serves, but the installer rejected roughly 850
  of them -- and did it at the very end, after the download, after unpacking
  the game code and assets, and after hashing the game library. Choosing
  1.14.60.5 cost a 200 MB download and a full extraction before reporting
  "unsupported".
- The refusal now distinguishes two cases. Blocked means the port cannot run it
  whatever anyone wants -- PairIP licensing (1.26+), or an unparseable version
  -- and no confirmation unlocks it. Untested means only that nobody has run it
  here, which is the user's risk to take. The check runs before any work, so a
  refusal is immediate.
- Picking an untested set from Install APK now says what is wrong with it and
  offers "Install it anyway". Downloads are already confirmed on the download
  screen, which carries the same warning, so they are not asked twice. An
  untested build records itself as such in version.json.
- Installing a version that is already installed is no longer reported as a
  failure. It said "APK setup failed: version already installed", which is what
  reinstalling 1.16.0.2 looked like even though that version was present and
  working.

## v2.0.0-rc.8 (testing)

- Held up/down now repeats in the launcher menu. The version browser lists over
  a hundred builds and every one of them had to be stepped past with a separate
  button press. A tap still moves one row; holding starts after a short delay,
  then moves ten rows a second and accelerates to twenty-five. Left/right is
  excluded because it toggles ARM64/ARM32.
- Every row in the version browser now carries the same markings the desktop
  helper shows in its columns: RenderDragon or not (stated both ways, because
  "No RenderDragon" is a reason to pick a build), Bedrock or Pocket Edition
  with touch-only spelled out, the named update, and whether the UI is tiny on
  a handheld screen. The Play code moved off the row to make space; it was
  already on the confirmation screen, along with the full warning text.
- Whether a build has a tiny UI is now its own catalog column instead of
  something the menu picked out of the notes prose, so there is still exactly
  one implementation of the classification, shared with the Windows helper.
- Fixed menu text colliding with the lines around it. The header's port version
  had a 92px wrap limit for a 135px string, so it wrapped and the second line
  landed on the accent rule; the subtitle could wrap the same way and did on
  640px-wide devices; list rows placed a title and description at fixed
  fractions of a row too short to hold both, so the description ran under the
  title and through the row's bottom border; and the "1/111" position counter
  was aligned to the screen rather than the list frame, crossing its border.
  Text in these places is now sized and placed from the font's own metrics, and
  trimmed rather than wrapped.
- Baked the menu backdrop's dot grid and scanlines into a single static
  SpriteBatch. They never change, but they cost about 1500 draw calls per
  frame, which a held direction now redraws continuously.

## v2.0.0-rc.7 (testing)

- Restored the shared-data migration that understands a hidden
  `.minecraftbedrock-data` directory. rc.5 and rc.6 shipped a version that knew
  only the visible name, so on a device whose data directory is hidden -- which
  is how Knulli keeps the shared tree out of its recursive Ports inventory --
  the port refused to start, reporting the symlinks as pointing at an
  "unexpected target". It refused rather than damage anything, but it refused.
  Found by installing rc.6 on a real RG34XXSP that rc.4 ran on. The working
  version, and the test covering it, had both been sitting uncommitted, so the
  releases cut from main silently went backwards and CI had nothing to catch it
  with.

## v2.0.0-rc.6 (testing)

- Reduced the Windows helper's first run to one button. Step 1 now installs the
  Windows Subsystem for Linux (through Windows' own administrator prompt rather
  than instructions to find an elevated PowerShell), installs Ubuntu with
  `--no-launch`, and builds gplaydl, reporting progress in the window. Every
  command inside the distribution runs as root, so there is no Linux username or
  password to create, no `sudo` prompt, and no terminal window; an install made
  by an earlier helper under a normal user's home is adopted instead of rebuilt.
  Before anything is installed the helper states plainly that it is putting a
  complete Ubuntu Linux system inside Windows, with sizes and the
  `wsl --unregister Ubuntu` way back out.

- Made the Windows helper state, on every row, which edition a build is
  (Pocket Edition below 1.2, Bedrock above, with Pocket Edition marked touch
  controls only), the named update it belongs to, and whether it uses
  RenderDragon. RenderDragon rows are drawn in red and warn before downloading.
  The Android RenderDragon boundary is 1.18.30, not 1.17 — the renderer shipped
  per platform and reached Android last, with 1.21.51 shipping it disabled on
  arm64 only, and the 1.21.51.02 Android re-upload that restored it is a
  separate build with its own Play code, flagged accordingly. Update names come
  from the minecraft.wiki release infoboxes;
  releases that were never named are left blank.

- Rebuilt the Windows helper's window: every version Google Play still serves
  for the selected architecture is now in one scrollable, searchable list read
  from mcpelauncher-versiondb, rather than a fixed row of nine buttons. The
  tested builds keep their notes and are marked; beta and preview builds are
  behind a checkbox. The list is cached for a day under
  `%LOCALAPPDATA%\mcbedrock-get\versiondb\`, and with no network and no cache
  it falls back to the tested builds, whose codes ship inside the helper.
  `--list` prints the same catalog and `--download` accepts anything in it.
- Made the helper DPI-aware, so its text is drawn rather than bitmap-stretched
  on a scaled display, and gave it a dark theme, real download percentages, and
  a matching dark title bar.
- Dropped the helper's email field. Google's own sign-in page asks for the
  address moments later, so the helper reads back which account that session
  belongs to instead of asking twice. The read is made from inside the
  signed-in page and never by navigating the sign-in window, which would put
  Google's error page in front of the user; if it comes back empty the helper
  asks for the address while still holding that sign-in, so no one ever signs
  in twice.

- Reworked **Get APK from Google Play** so the post-confirmation phase reports
  real browser/runtime, Google-session, download-percentage and validation
  milestones instead of leaving the confirmation tile frozen. Added a clearly
  separated compact catalog containing every Google Play ARM64 and ARM32
  release/preview in the supported 1.16-1.21 range (685 architecture-specific
  builds in the current upstream snapshot). Architecture and channel filters,
  Play code and risk information are shown in the list/confirmation flow;
  unsupported 1.26+ PairIP builds stay excluded.
- Removed the multi-second pre-menu delay. The launcher caches validated
  native-library fingerprints by size/mtime/ctime, resolves the selected
  version once, and avoids starting Python again when the APK inventory has
  not changed. The measured RG34XXSP/Knulli first frame is now 3.35 seconds,
  so the temporary loading panel was removed. Startup phase timings are
  retained in `logs/startup-timing.log`.
- Corrected the final RG34XXSP native face-button detail by swapping only A/B;
  the now-verified D-pad, X/Y, shoulders, triggers, sticks, and menu mapping are
  unchanged.
- Reworked host selection around device capabilities: H700 stays arm64 on
  Knulli and muOS regardless of RAM, while RK3326/R36S selects the armhf
  KMSDRM path. Knulli, muOS, generic ROCKNIX/Sway, RGDS/ROCKNIX, and dArkOS
  fixtures now guard the backend contracts.
- Removed normal-path frontend process management from the port. PortMaster's
  platform helper owns suspension/restoration; explicit menu failures return
  visibly instead of silently autoplaying Minecraft.
- Added APKM, APKS, XAPK, and ZIP bundle input with bounded private expansion,
  non-stale kernel locking, durable transaction journals, and power-interrupt
  rollback that refuses to delete targets from another transaction.
- Added exact controller-name aliases for the generic H700 GUID, implemented
  GUID-plus-name lookup in linux-gamepad, and reproducibly rebuilt/deployed the
  arm64 client. The patch also fixes an upstream low-key-code button-table
  out-of-bounds write.
- Normalized a working UTF-8 locale and private mode-0700 runtime directory,
  recorded a whitelisted runtime environment, and expanded the redacted
  support bundle with audio, graphics, storage, controller, and ELF evidence.
- Ran the complete host suite and deployed the script-level checkpoint to the
  RG34XXSP/Knulli Scarab reference device with a recoverable code backup.

## v2.0.0-rc.4 (testing)

- Fixed the Windows helper hanging for five minutes at **Passing your Google
  session to the downloader**. The upstream interactive master-token path
  retried forever after its initial verification request failed and stdin had
  already closed.
- Replaced that prompt automation with the upstream non-interactive
  `--login-no-verify` path, which was verified against Google Play with the
  same valid account token. The private WSL config is transferred only over
  stdin, normalized to Linux line endings, stored with mode `0600`, and never
  placed in a process command line.
- Require both the WSL credential config and service-token cache before a
  session is considered ready. Failed or timed-out setup removes partial
  state and now returns an actionable error instead of a raw subprocess
  timeout.

## v2.0.0-rc.3 (testing)

- Rewrote the GitHub and packaged READMEs around a beginner-first install
  path: exact edition downloads, per-firmware extraction locations, Windows
  WSL setup, ABI selection, complete split-set transfer, launcher steps,
  updates, RGDS limitations, and symptom-based troubleshooting.
- Hardened and published the Windows helper as a versioned bundle with pinned
  build tooling, deterministic packaging, generated notices, WSL distro
  discovery, isolated downloads, complete arm64-set validation, enforced
  timeouts, safe redownloads, and Windows-plus-WSL sign-out.
- Fixed clean-checkout release CI by tracking the pinned client/companion
  container recipes, adding Windows helper tests/builds, scanning every ZIP,
  and guarding public documentation against stale paths and claims.
- Added a Windows helper, `tools/mcbedrock-get`, that signs in with the
  user's own Google account and downloads the arm64 split APKs for the
  recommended 1.16.221.01 and the newest tested 1.21.51.01. Google no longer
  serves Play downloads to third-party desktop clients, so the download itself
  is delegated to `gplaydl` from minecraft-linux/google-play-api running under
  WSL, which is also the only client that accepts a specific older version
  code. A result without an `arm64_v8a` split is refused rather than written,
  so an x86 download cannot reach the device. The helper bundles and
  distributes no game content; Play refuses accounts that do not own Minecraft.
- Documented obtaining APKs on Windows in `GETTING-BEDROCK-APKS.md`, covering
  the helper and the manual launcher route, the arm64-versus-x86 mistake,
  and how to group one download into a complete split set.
- Fixed installation appearing to freeze the device. The launcher menu exits
  before extraction begins, leaving its last frame on screen for the minutes
  that follow. The installer now publishes progress and stage, and the launcher
  draws a bar until extraction finishes. It stays inert where it cannot draw —
  under sway, or with no writable `/dev/tty1` — so Wayland/Sway, KMSDRM, Mali
  Weston, and X11 hosts behave exactly as before.
- Fixed 1.16-era split sets being rejected with "split set must contain exactly
  one base APK". A split name, not the payload, identifies the base, but the
  resource-pack test ran first and 1.16 keeps its assets inside the base APK.
  A base carrying resource packs now also satisfies the assets requirement.
  1.21.51.01 is unaffected: its `install_pack` declares a split name.
- Placed the canonical package tree, RGDS companion sources, release scripts,
  and the host-side test suite under version control. Build scratch, release
  staging, and local research directories stay excluded from the repository.

- Replaced the Chat and Items framebuffer mirrors with independent lower-screen
  views. Gameplay remains visible on the other panel; companion touches are
  consumed locally and expressed as bounded, versioned commands.
- Added an AYN-style 36-slot inventory surface, craftable recipe pane, chat
  history pane, and touch keyboard. Unsupported actions remain visibly
  read-only and are rejected rather than editing player memory.
- Added runtime indexing and PNG loading for the user's installed Bedrock
  resource packs. The port never packages or redistributes Mojang artwork.
- Added a fail-closed `1.21.51.01` native profile pinned to library SHA-256
  `45382be72491ec2cbe5dd4d1262989ad894b8fc611e5cbc16141d04171510927`.
  It validates RTTI, the vtable target, and the instruction prologue before
  changing a game-library pointer.
- Fixed bottom-panel touch injection on the installed ROCKNIX/Sway build by
  using its accepted unquoted input-identifier syntax.
- Removed the render readback/mirror writer from the RGDS launcher client.

## v2.0.0-rc.2 (testing)

- Rebuilt the RGDS lower-screen UI around a persistent status stack and five
  Minecraft-style bottom tabs: HUD, Chat, Items, Input, and Settings. The HUD
  centers the terrain map; Input provides a 3×3 shortcut grid; settings expose
  status, automatic Items selection, map night tint, and player following.
- Added LevelDB snapshot health/hunger/dimension/world-time consumption and
  on-demand Bedrock framebuffer mirroring for Chat and Items with lower-panel
  touch forwarding. Capture stops off those tabs and stale frames fall back to
  an explicit unavailable state instead of freezing or blanking the display.
- Changed the RGDS release contract to require both telemetry and mirror hooks
  in the pinned launcher client. The standard edition remains free of all
  dual-screen markers and behavior.
- Fixed the RGDS companion retaining terrain from the last local world after
  joining another device's world over LAN. The client now detects direct
  Bedrock network peers, invalidates cached local tiles and waypoints, pauses
  local LevelDB rendering, and displays an explicit remote-world/map-unavailable
  state while keeping live position and status telemetry.
- Extended remote-session detection to IPv6 and direct public Bedrock peers;
  IPv4-only detection missed the physical RGDS-to-RG34XX-SP LAN path.
- Fixed delayed/inconsistent local-world selection by following the LevelDB
  directory actually opened by the game instead of waiting for movement to
  update a database log's mtime. Reduced the default scan radius from 24 to 12
  chunks and publish the central visible area before any configured outer ring.
- Restored bottom-panel touch by shipping the stable RGDS `bottomd` target,
  which follows the displayed map panel through dynamically discovered raw
  evdev devices rather than falling back to unreliable Wayland touch routing.
- Kept LAN packet contents and peer addresses out of telemetry, logs, and
  support bundles; the detector records only a short-lived remote-session flag.
- Made 1.16.221.01 the recommended/default no-RenderDragon version for its
  handheld-friendly UI scaling, while fingerprinting the original
  1.21.51.01 library as the newest tested no-RenderDragon arm64 option.

## v2.0.0-rc.1 (testing)

- Split the port into a lightweight universal standard edition and a separate
  arm64 RGDS dual-screen edition, both using the same shared user-data root.
- Replaced Bedrock directory-name heuristics with manifest metadata, guarded
  compatibility rules, and native-library fingerprints.
- Made Bedrock 1.16.221.01 the recommended/default version because its UI
  scaling is the most usable on handheld displays.
- Registered the exact original no-RenderDragon 1.21.51.01 native library as
  the newest tested no-RenderDragon arm64 build. Later or unknown reuploads
  using the same version name show a warning and are never selected by default.
- Moved RenderDragon-era builds to optional, non-blocking compatibility smoke
  coverage because their stutter makes them unsuitable recommendations on the
  physical reference devices.

## v1.6 (2026-07-10)

- **New launcher menu.** Starting **Minecraft Bedrock** now opens a full
  controller-driven launcher (LÖVE) instead of the bare version list, and it
  now also runs on fbdev devices (Knulli/muOS H700) — previously it only
  appeared on kmsdrm/ROCKNIX devices:
  - **Versions**: switch the active version (remembered across launches) or
    delete installed versions; worlds/profiles are never touched.
  - **Install APK**: install new versions from APK files in `apk/` — a
    single file or a whole Google Play split set — and delete the APK files
    afterwards, all from the device.
  - **Settings** (persisted in `config/settings.cfg`, applied every launch):
    FPS cap, render distance in chunks (can go below the in-game slider's
    minimum), 64/32-bit client override, UI scale, VSync, performance
    governor, options auto-tune, FPS logging.
  - **Backup**: archive worlds, game options, and launcher settings into
    `backups/` as tar.gz, and restore or delete archives — all on-device.
  - **Help**: short on-device troubleshooting guide.
  - The menu stops/restores the CFW frontend itself where needed, and any
    menu crash falls back to the old newest-version autostart.
  - The menu UI is original to this port: procedural pixel-art chrome
    (no image assets; the old gameplay-screenshot background is gone) with
    the OFL-licensed Monocraft font, sized for small handheld screens.
  - Button mapping matches the printed labels on the pad (confirm on the
    button printed A, back on B, delete on X). Whether the CFW's SDL mapping
    is positional (H700 family) or label-based (RG DS) is detected per pad
    GUID; `MCPE_MENU_CONFIRM=a|b` overrides it for unlisted pads.
  - FPS cap covers 10–120 in 5 fps steps.
  - Pressing Play shows a **LAUNCHING pop-up** with the chosen version and a
    progress bar; it stays on screen while the game boots, so the seconds
    between the menu and the game no longer look like a freeze.
  - **3D widget set**: every menu row is a chunky extruded 3D button (hard
    outline, lit top edge, darker bottom side; the selected one lifts and
    glows green), On/Off settings are large toggle switches with I/O marks,
    FPS cap and render distance are thick sliders with a notched groove and
    a two-tone striped fill, main-menu entries carry 8×8 pixel icons, footer
    hints are 3D keycaps, and the LAUNCHING pop-up uses a sweeping
    slider-style loading bar. Knobs are chamfered octagons with grip lines —
    an original silhouette rather than square game-style widgets.
- Explicit FPS-cap / render-distance / VSync choices are now written into
  the game's `options.txt` even on a brand-new profile (previously they only
  applied if the game had already written the key) and are applied
  independently of the `MCPE_PERFORMANCE_OPTIONS` guardrail toggle.
- Fixed: an APK left in `apk/` after installation no longer makes every
  launch fail with "version already exists" — with the menu available,
  installs are user-driven; on menu-less devices a failed re-extraction now
  falls back to the installed versions instead of aborting.
- The CFW's SDL controller mapping is now actually exported to the menu
  (it was fetched but never passed on), fixing swapped/misplaced buttons in
  the selector on some devices.
- `setup_apk.sh` accepts explicit APK paths as arguments (used by the menu).
- `port.json` and the release zip now ship only the main **Minecraft
  Bedrock** entry; version selection (including 1.16) and port updates live
  inside the launcher menu.

## v1.5.1 (2026-07-09)

- Fixed the port not launching on Knulli when installed in the v1.5 split
  layout (`roms/ports/` scripts + `ports/minecraftbedrock/` payload): the
  PortMaster control files the main entry sources can clobber `SCRIPT_DIR`,
  making the game folder resolve to `/minecraftbedrock`. The entry now
  restores its script directory after sourcing. Verified on an RG34XX-SP
  running Knulli (Scarab).
- Fixed silent audio on Pulse-served systems (Knulli and ROCKNIX,
  pipewire-pulse): since v1.4 the launcher was started with
  `SDL_AUDIO_DRIVER=openal` — that is SDL3's effective hint name and
  "openal" is not an SDL3 audio driver, so SDL3's audio subsystem failed to
  initialize and the game was mute. `SDL_AUDIO_DRIVER` is now only passed
  when a driver is explicitly selected (the muOS PipeWire-without-Pulse
  path, or the `MCPE_SDL_AUDIODRIVER` override); otherwise SDL3 keeps its
  default driver order and picks PulseAudio. muOS is unaffected. Verified
  on an RG DS running ROCKNIX and an RG34XX-SP running Knulli.

## v1.5 (2026-07-09)

- **One release zip for everything.** The universal and `-muos-sdroot`
  variants are replaced by a single `minecraftbedrock-<version>.zip` that
  installs by extracting it at the SD card / share root — no install
  scripts, no manual file placement. The launch entries ship at both
  `roms/ports/` (muOS `ROMS/Ports` via FAT case-insensitivity, Knulli
  `roms/ports`) and `ports/` (ROCKNIX-style layouts); the port payload
  ships once at `ports/minecraftbedrock/`. The classic
  "everything together in your ports folder" layout still works — the
  launch entries look next to themselves first.
- The **Minecraft Bedrock Update** entry understands the new zip layout
  (and the old one) and now also finds split installs where the scripts
  live in `roms/ports/` and the payload in `ports/` at the same root.
  Updating from v1.4/v1.4.1 with the old updater still works: the new
  zip is rejected safely — extract the v1.5 zip once by hand, after
  which in-place updates resume.
- Removed the PC-side `tools/prepare_sd` scripts — the single zip made
  them unnecessary.
- Confirmed working on muOS 2601 (RG34XX-SP), including audio; docs now
  describe the unified install on muOS, Knulli, and ROCKNIX.

## v1.4.1 (2026-07-09)

- Actually fixed silent audio on muOS (PipeWire without a Pulse socket).
  v1.4's approach could not work: the shipped client's static SDL3 has no
  PipeWire driver compiled in, so `SDL_AUDIODRIVER=pipewire,alsa` silently
  degraded to raw ALSA — and PipeWire holds the sound card exclusively
  ("Device or resource busy"). On top of that, muOS's minimal ALSA config
  does not advertise a `default` device in the namehint list, which SDL3
  requires before it will open `default`, so SDL3 opened the raw card
  directly. The port now ships `alsa/pipewire-overlay.conf` and, when it
  detects PipeWire with no Pulse socket, generates a private ALSA config
  (`ALSA_CONFIG_PATH`) routing `default`/`sysdefault` through the system's
  ALSA→PipeWire plugin. Verified on an RG34XX-SP running muOS 2601
  Jacaranda: active in-game PipeWire stream, audible sound. Knulli and
  ROCKNIX are unaffected (they take the Pulse path); disable with
  `MCPE_ALSA_PIPEWIRE=0`.
- The port README shipped inside v1.4 zips still described an internal R36S
  test build in its Download section; it now matches the public release.

## v1.4 (2026-07-08)

- Fixed silent audio on PipeWire-without-Pulse systems (muOS Jacaranda):
  raw ALSA fell back to "Device or resource busy" because PipeWire holds the
  device exclusively. The launcher now detects the PipeWire socket and routes
  SDL audio through it (`pipewire,alsa`), and exports `PULSE_SERVER` when a
  Pulse socket lives in a nonstandard location. Knulli/ROCKNIX unchanged.
- Fixed the game laying its UI out for 720x480 on other panels (e.g. 640x480
  RG35XX-H reported `getScreenWidth=720`): the client window is now requested
  at the real panel size via `-ww`/`-wh`.
- APK setup now fails fast with specific on-screen reasons: PairIP 1.26+
  Play builds, non-ARM ABIs (listing what was found), missing split parts,
  and corrupt archives — instead of a generic "extraction FAILED".
- Added PC-side SD preparation tools (`tools/prepare_sd.ps1` / `.sh`): verify
  the release zip, lay files out for Knulli/muOS/ROCKNIX, and validate the
  APK on the computer before the first on-device launch.
- Added `scripts/build_release_zips.py` + CI workflow: builds the universal
  and muOS SD-root zips from one staging tree with checksums and the content
  safety check.
- Added a **Minecraft Bedrock Update** Ports entry: downloads the latest
  release from GitHub and updates the port's scripts/binaries in place —
  worlds, settings, and installed game versions are never touched. Ships
  with a `PORT_VERSION` stamp (written by the release build script).
- Replaced the menu fonts with Monocraft (SIL OFL 1.1) — the previous
  fan-made fonts had unclear/personal-use-only licensing and could not be
  redistributed cleanly. License text added to `licenses/`.

## v1.4-r36s-test

- Added a dual-ABI launch flow: 64-bit aarch64 EGLUT/Weston remains the
  default for tested 64-bit devices, while RK3326/R36S-class devices can run
  the bundled 32-bit armhf SDL client from the working R36S port.
- Fixed the R36S/armhf packaging path by restoring bionic `libc.so`/`libm.so`
  shim visibility during APK extraction and launch.
- Added ABI auto-selection and `MCPE_ABI_OVERRIDE=armhf|arm64` for testing
  dArkOS/DarkOS RE, Aurknix, and ArkOS-for-clone variants.

## v1.3.1

- Fixed silent audio on ALSA-only systems with no PulseAudio/PipeWire server
  (e.g. muOS): the launcher now detects the missing server and routes its
  OpenAL output to ALSA automatically. Knulli and ROCKNIX are unchanged.
  Override with `MCPE_ALSOFT_DRIVERS`.

## v1.3

- Added muOS compatibility for H700 devices: split `/roms/Ports` + `/ports`
  install layout, `MUOS/PortMaster` runtime lookup, muOS frontend stop/restart,
  and Mali device-node fallback.
- Packaged a manual-install release for aarch64 handhelds.
- Added support for user-supplied single APKs and Google Play split APKs.
- Added a separate 1.16.221.01 launch entry with isolated profile data.
- Documented that 1.16.221.01 has a working GUI Scale slider and runs
  perfectly without stutters on tested devices.
- Included GPL source patches and license texts for shipped components.
- Added legal, support, credit, testing, checksum, and release-safety docs.
