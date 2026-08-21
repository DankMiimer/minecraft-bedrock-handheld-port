# Active handoff — on-device Google Play downloader UI

Last updated: 2026-08-14. This section is the current resume point; the older
Windows research below is retained as historical evidence.

## Current request

Improve **Get APK from Google Play** on the RG34XXSP/Knulli reference device:

1. After **Continue to Google sign-in**, replace the apparently frozen confirm
   frame with truthful progress/status until the Google browser is ready.
2. Add an experimental path for all catalogued 1.16-1.21 arm64 and arm32
   releases/previews, using a dense list rather than more tiles.
3. Put more useful compatibility, architecture, storage and sign-in information
   directly on the downloader tiles.

## Current device/release state

- Device: RG34XXSP, Knulli Scarab, `192.168.1.25`, SSH `root`/`linux`.
- The launch-time work immediately preceding this task is deployed. A real ES
  launch reached the LOVE menu's first frame in **3347 ms**; the user confirmed
  it is fast and asked to remove the temporary startup loading screen.
- Native game mapping on the device is `a:b1,b:b0,x:b2,y:b3`; the separate
  LOVE/SDL menu map must not be changed.
- Full Linux test suite passed before the final loading-panel removal; platform,
  performance, docs and portability checks passed afterward.
- Recoverable device backup from the launch work:
  `/userdata/roms/ports/minecraftbedrock-code-before-startup-opt-20260814.tar.gz`.
- Latest support bundle:
  `/userdata/roms/ports/minecraftbedrock/support-bundle-startup-final-20260814.tar.gz`.

## Downloader trace and implementation decision

- LOVE currently calls `quitWith("download_apk", code)`. The shell then runs
  `menu_do_download`, which invokes `downloader/run.sh` synchronously.
- Before `run_google_gui()` presents Weston/Qt, `run.sh` may locate/download and
  extract the 141 MiB AppImage (~550 MiB installed), install the Qt keyboard,
  mount Weston and Mesa, and create Qt plugin views. None of these phases
  currently report to the display. Knulli therefore keeps showing the last
  confirmation frame, which looks frozen.
- Implemented fix: `run.sh` atomically publishes milestone progress to a private
  progress file. `Minecraft Bedrock.sh` runs it in the background and renders a
  dedicated LOVE progress surface before/after the interactive Weston browser.
- The `interactive` protocol phase uses an ack handshake, guaranteeing LOVE has
  exited before Weston/Google takes Mali; a tty renderer is fallback only.
- Existing install progress remains separate and begins only after the APK set
  has been downloaded and validated.

## Files expected to change

- `portmaster/minecraftbedrock/Minecraft Bedrock.sh`
- `portmaster/minecraftbedrock/minecraftbedrock/downloader/run.sh`
- `portmaster/minecraftbedrock/minecraftbedrock/downloader/validate_download.py`
- `portmaster/minecraftbedrock/minecraftbedrock/menu/main.lua`
- downloader/port documentation and regression tests

## Implementation completed so far

- `downloader/run.sh` now atomically writes
  `percent|active|heading|detail`; `interactive` replaces `active` while
  Weston/Google owns the framebuffer. Milestones cover runtime, keyboard,
  graphics, approval exchange, live `Downloaded N%` parsing, and validation.
- `Minecraft Bedrock.sh` backgrounds the downloader and renders those stages in
  fullscreen LOVE, fully releasing/reacquiring the display around Google.
- Download requests now carry `version-code:abi`; both the launcher and
  downloader enforce the same exact allowlist.
- Added `device-armhf.conf` and ABI-aware validation. A generated catalog now
  contains every upstream ARM64/ARM32 release and preview in the supported
  1.16-1.21 range: 685 architecture-specific entries in the current snapshot.
  Up/down chooses a build, left/right changes architecture, and X changes
  release/preview channel. The proven arm64 codes remain as first-screen
  shortcuts; 1.26+ PairIP builds are deliberately absent.
- Main downloader actions remain paged tiles with expanded architecture,
  validation level, target and risk descriptions. **Other versions
  [EXPERIMENTAL]** opens a dense filtered list rather than more tiles.
- The redacted support bundle now includes `logs/downloader.log`; tokens and
  authorization-like fields still pass through the existing redactor.
- Live `fbgrab` QA caught overlapping wrapped lines in the new information
  dialog. The generic confirmation renderer now advances by the actual
  `Font:getWrap()` line count, improving all long warning dialogs.
- The privacy/sign-in explanation no longer abuses a Yes/No confirmation. It
  has a dedicated static `download_info` screen with only B=back, fixing both
  the duplicated “No, go back / Back to downloads” navigation and the useless
  selectable-focus/“up/down read” hint.
- A second live `fbgrab` proved that tty milestones were being written but
  remained hidden behind Knulli's retained LOVE/Mali frame. The implementation
  now uses `downloader/progress-ui/main.lua`, a dedicated fullscreen LOVE
  progress surface. Before Weston/Google starts, `run.sh` publishes
  `interactive` and waits for an ack; the parent waits for LOVE to exit, writes
  the ack, and restarts progress only after Weston cleanup publishes `active`.
  The same surface now renders APK install progress when LOVE is available.
- `gplaydl` resets `Downloaded N%` for every split. The overall milestone bar
  now stays at 84% during transfer and labels N% as the **current APK file**,
  avoiding a misleading backwards progress bar.
- The first live 1.21 run exposed a performance bug in the output parser: it
  spawned `tee` for every carriage-return redraw and spent minutes draining
  duplicated 91% lines after `gplaydl` had exited. The parser now uses shell
  builtins/direct append and records only percent changes. Validation remains
  authoritative even if upstream exits nonzero.

## Verification/current resume point

- `bash -n`, Python compile, downloader unit tests, docs, portability contracts,
  `git diff --check`, and the complete `tests/run_all.sh` Linux matrix passed
  during this downloader pass. After the final catalog/filter revision, the 10
  focused downloader tests and scoped diff check pass again.
- Runtime files are deployed. Device-side `bash -n` for the port/downloader and
  `/usr/bin/luac -p menu/main.lua` pass. On-device catalog checks accept the
  newest ARM64 and oldest ARM32 release examples while rejecting an absent
  PairIP code and a real code paired with the wrong ABI.
- Pre-change device backup:
  `/userdata/roms/ports/minecraftbedrock-code-before-downloader-ui-20260814.tar.gz`.
- Final redacted diagnostic snapshot:
  `/userdata/roms/ports/minecraftbedrock/support-bundle-downloader-catalog-final-20260814.tar.gz`.
- Final clean framebuffer QA on the RG34XXSP passed with ES paused before LOVE:
  the ARM64 release catalog shows 9 rows at once and `1/110`; left/right changed
  it to ARM32 and X changed it to previews with `1/235`. The sign-in/storage
  page has no selected row, no overlap and only `B back to downloads`.
- The live 1.21.51.01 transfer downloaded and strictly validated all five APK
  splits. Its old shell instance later printed an EOF quote error because
  `run.sh` was replaced while that very instance was still reading it; the
  deployed file is syntactically valid and a clean future launch is unaffected.
- The dedicated graphical progress surface was visibly proven on-device. A
  completely fresh Google handoff was not repeated after the final catalog UI
  change because the user's private session is saved; exercising it again would
  require the explicit Sign out action. Do not silently remove that session.
- ES-DE was resumed after QA, forced to redraw, and left cleanly at All Games;
  only the normal ES-DE wrapper/frontend processes remain.

## Important constraints

- No game content is bundled; download requires the user's purchased Google
  Play copy and Google's own sign-in/approval UI.
- Keep proven downloads visually distinct from experimental versions.
- The installer may support both `arm64-v8a` and `armeabi-v7a`, but the
  on-device Google UI/runtime itself is currently an arm64 H700/Knulli
  prototype. “arm32” describes the downloaded game split for an armhf target,
  not running this downloader on an armhf OS.
- Never label arbitrary version codes as supported. 1.26+ PairIP builds remain
  blocked by policy; older experimental builds must be clearly marked untested.
- `gplaydl` can exit nonzero after writing a complete set. File validation, not
  its exit code, remains authoritative.

---

# Archived Windows downloader research handoff

> Historical implementation notes. Several filenames and conclusions below
> predate the working WSL/gplaydl helper. Current behavior is documented in
> [`tools/mcbedrock-get/README.md`](tools/mcbedrock-get/README.md).

# Handoff — Bedrock APK downloader for Windows

Working notes so this can be resumed cold. Last updated during the `gplaydl`
integration.

## Goal

Let a Windows user sign in with their own Google account and download
**1.16.221.01 arm64** (code `971622101`) and **1.21.51.01 arm64** (code
`972105101`) for the handheld port, with as little ceremony as possible.

## What is settled (do not re-investigate)

| Finding | Evidence |
|---|---|
| `gpapi` (Python Play client) **cannot download** | Every version code returns `DF-DFERH-01`, including newest |
| Not a config problem | Replicated minecraft-linux's device profile exactly (SDK 36, Play client 45.8.21, `diy/desktop` fingerprint) — identical failure |
| Not locale, not terms, not ownership | Locale probe changed the title only; terms already accepted; Play web UI confirms account owns Minecraft |
| Not the account | Free apps (`com.android.chrome`, maps) return full details with versionCode; Minecraft returns 7 fields, no version |
| Cause | gpapi's 2019-era protocol. Google now refuses it |
| Raccoon (Java) | Broken by Google, Feb–Mar 2026 (its own issue tracker) |
| apkeep (Rust) | "Paid and DRM apps will not be available" |
| **minecraft-linux `google-play-api` works** | mcpelauncher downloaded successfully 2026-08-11 on this account |
| A phone cannot help | Play only installs the current build = 1.26 line, which the port rejects (PairIP) |

## Current plan

Reuse only components proven to work:

1. **Sign-in** — the existing WebView2 flow in `tools/mcbedrock-get/playstore.py`
   (`harvest_oauth_token`). This works; it returns Google's `oauth_token` cookie.
2. **Download** — `gplaydl` from minecraft-linux/google-play-api, built **inside
   WSL** (Linux build; avoids the Windows MSVC toolchain problem entirely).
   Authenticates from an OAuth token: `gplaydl --interactive --device device.conf
   --save-auth --accept-tos`, then pick option 2 (access token) and paste it.
3. **UI** — reduce the existing Tk window to two buttons + progress, shelling out
   to `wsl -d Ubuntu -- gplaydl ...` and copying results to a Windows folder.

Known limitation, accepted by the user: WSL is still required, because the
downloader is a Linux binary. Removing that means porting google-play-api to
MSVC, which was considered and declined.

## Progress

- [x] Guide written: `GETTING-BEDROCK-APKS.md` (manual WSL route, works today)
- [x] Release wiring un-picked — no Windows binary is published
- [x] App rewritten barebones: two version buttons, `signin.py` + `wsl_backend.py`
- [x] `wsl-setup.sh` writes `device-arm64.conf` and builds `gplaydl`/`gplayver`
- [x] Dead gpapi path deleted (`playstore.py`, `versions.py`, `compatibility.json`)
- [x] Exe builds, 18.3 MB, `--check` reports setup state correctly
- [x] Fixed regression: sign-in must run via `login_in_subprocess()`. pywebview
      demands the main thread, which the Tk window holds — calling it from a
      worker thread hangs on "Waiting for the Google sign-in window…"
- [x] "Download" now offers to run `wsl-setup.sh` in a visible console
      (`CREATE_NEW_CONSOLE`) so sudo can prompt
- [x] Fixed setup loop: `wsl-setup.sh` had `set -e`, so a non-zero
      `apt-get update` (third-party minecraft-linux repo) aborted it before
      installing anything, and the console closed instantly hiding the error.
      Now: update failure tolerated, every step checked, window always pauses.
      Verified the packages have valid candidates (protobuf 3.21.12,
      curl 8.5.0) and 70 apt lists exist, so no update is actually needed.
- [x] `wsl-setup.sh` run successfully — gplaydl + gplayver built and installed
- [x] **WORKING END TO END.** Both versions downloaded with arm64 splits:
      `minecraft-971622101.config.arm64_v8a.apk` (135 MB) and
      `minecraft-972105101.config.arm64_v8a.apk` (68 MB), in
      `Documents\MinecraftBedrockPort`. `--check` reports all green.

## Bugs found during the end-to-end run (all fixed)

- Sign-in used `gplaydl --app-version 0`, which authenticated and then tried to
  download version 0. Now uses `gplayver`, which only authenticates.
- `gplaydl` **returns non-zero even after a complete download**. Never judge
  success by its exit code — check the files on disk.
- Success was measured as *new* files versus a pre-scan, so re-downloading an
  existing version reported "no files". Now globs `minecraft-<code>*.apk`.
- gplaydl redraws progress with carriage returns, which text mode turns into
  thousands of lines; the UI queue drowned. Now only reports on percent change.
- Windows Defender blocks the fresh exe on first run (PyInstaller heuristic).

## On-device work

- **1.21.51.01 from the downloader runs on the RG34XX-SP.** Whole pipeline proven.
- **Install progress bar added.** The freeze was not a hang: the LÖVE menu
  *exits* (`quitWith("install")`), then the shell extracts with nothing drawing,
  leaving the last frame on screen. Now `apkmeta.py` publishes
  `<percent> <message>` to `$MCPE_PROGRESS_FILE` (atomic write via a `.tmp` +
  `os.replace`, or the poller sees an empty file and the bar snaps to 0), and
  `draw_install_progress()` in `Minecraft Bedrock.sh` renders a bar on
  `/dev/tty1` until the installer exits.
- Verified with the real 1.21 APKs: `0 → 31 → 42 → 60 → 74 → 99 finishing`,
  exit 0, `1.21.51.01-972105101-arm64` installed. `tests/run_all.sh` passes.
- Known gap: like `show_msg`, the bar is skipped under sway (RGDS), which has no
  writable `/dev/tty1`. RGDS still shows nothing during install.

## Fixed: 1.16.221.01 installs

1.16's Play delivery puts the assets *inside* the base APK, and `inspect_apk`
tested `has_resource_packs` before `not manifest.get("split")`, so the base was
classified `assets` and the set had zero bases.

Two changes in `apkmeta.py`:
- the split attribute now decides the base, ahead of the resource-pack test;
- `choose_sources` uses the base as the assets source when there is no separate
  assets APK and the base carries resource packs.

Safe for 1.21 because `install_pack` **does** declare `split=install_pack`
(verified against the real files), so it is still classified `assets`.
Both sets verified INSTALLABLE; a real 1.16 install produced
`1.16.221.01-971622101-arm64` with a 139.9 MB `libminecraftpe.so`, 11,507 asset
files and `resource_packs/` present. `tests/run_all.sh` passes.

## Facts learned about gplaydl (do not re-derive)

- CLI: `gplaydl --device <conf> --accept-tos --app com.mojang.minecraftpe
  --app-version <versionCode> --output <path>` — `-v/--app-version` accepts an
  **arbitrary old version code**, which is the whole reason this route works.
- Splits are written by inserting the component id before the extension:
  `minecraft-971622101.apk` → `minecraft-971622101.config.arm64_v8a.apk`.
- Interactive login menu: `1` login+password, `2` access token, `3` master
  token. We feed **3** with the master token from `signin.py`.
- It writes `token_cache.conf` and `playdl.conf` into the **current directory**,
  so always run it with `cd` into the prefix.
- Build deps only: Threads, ZLIB, CURL, Protobuf. No OpenSSL. Ubuntu noble's
  protobuf is < 3.22 so abseil is not needed.
- Source: `~/gplaydl-src`, installs to `~/.local/share/mcbedrock-get/`.

## Key facts and paths

- Repo: `C:\Programmering\SBC\RG34xxSP\Minecraft_Bedrock_PortMaster`
- Tool source: `tools/mcbedrock-get/` (`mcbedrock_get.py`, `playstore.py`, `versions.py`)
- Build: `tools\mcbedrock-get\build.bat` → `dist\mcbedrock-get.exe`
- Credentials the tool writes: `%LOCALAPPDATA%\mcbedrock-get\account.json`
- mcpelauncher APKs in WSL: `~/.local/share/mcpelauncher/apks/`
- Port APK drop location on SD: `ports/minecraftbedrock-data/apk/`
- Version DB: `versions.arm64-v8a.json.min` from minecraft-linux/mcpelauncher-versiondb
- Compat registry: `portmaster/minecraftbedrock/minecraftbedrock/compat/compatibility.json`

## Gotchas that cost time before

- **Close the exe before rebuilding** — PyInstaller fails with `PermissionError`
  on `dist\mcbedrock-get.exe` if a window is open.
- **Store Python cannot read the credential file.** The venv interpreter is
  Microsoft Store Python, which redirects `%LOCALAPPDATA%`. Run diagnostics
  through the built `.exe`, not the venv.
- `gpapi` needs `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python` before import.
- PyInstaller needs `--copy-metadata gpsoauth`, or the frozen app dies in a
  silent dialog.
- Never call `toc()` — gpapi's version silently accepts Google's terms.
- Never hit Play's purchase endpoint for a title the account may not own.

## Diagnostics that still work

```bash
tools\mcbedrock-get\dist\mcbedrock-get.exe --diagnose   # account, terms, details, ownership
tools\mcbedrock-get\dist\mcbedrock-get.exe --probe      # per-version delivery attempts
tools\mcbedrock-get\dist\mcbedrock-get.exe --reset-device
```

## Uncommitted

Everything. Nothing has been committed this session.
