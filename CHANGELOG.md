# Changelog

## Unreleased portability checkpoint

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
  `%LOCALAPPDATA%\mcbedrock-getersiondb\`, and with no network and no cache
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
