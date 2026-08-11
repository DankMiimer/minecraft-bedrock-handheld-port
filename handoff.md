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
