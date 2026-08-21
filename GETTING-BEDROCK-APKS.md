# Downloading your owned Bedrock APKs

This guide obtains **1.16.221.01** (recommended), **1.21.51.01** (newest tested
original), or an explicitly experimental 1.16-1.21 build for the handheld port
from your own Google Play purchase.

**No game files are included.** This project does not host APKs, bypass a
license check, or download Minecraft for an account that does not own it.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Before you start

- The Google account must own Minecraft on **Google Play**. Xbox, Windows,
  Switch, PlayStation, Amazon, and Samsung purchases are separate.
- Select `arm64-v8a` for most 64-bit handhelds, H700 devices, and RGDS.
- Select `armeabi-v7a` for R36S/RK3326 users on 32-bit armhf firmware.

## Experimental on-device method (RG34XXSP + Knulli Scarab)

The standard port now has an optional **Get APK from Google Play** menu on a
64-bit H700 device running Knulli. Nothing is downloaded and no Google sign-in
is opened unless you select it; users who already have APKs can continue with
**Install APK** exactly as before.

1. Connect the handheld to Wi-Fi and open **Minecraft Bedrock**.
2. Choose **Get APK from Google Play**, then choose the recommended 1.16.221.01
   or tested 1.21.51.01 tile. **Other versions [EXPERIMENTAL]** lists all
   catalogued 1.16-1.21 ARM64/ARM32 releases and previews; use left/right for
   architecture and X for release/preview. Unknown builds may not work.
3. Confirm the first-use storage notice. A browser runtime may add about 700 MB
   after extraction; an already present compatible runtime is reused.
4. In Google's own page, use the controller-driven keyboard to enter the
   account password and approve the login on your phone when asked. D-pad moves
   the pointer, **A** clicks, **B** goes back, and the shoulders scroll.
5. Approve the launcher's one-time credential handoff. The port downloads the
   selected split set directly into `minecraftbedrock-data/apk/`, verifies
   its package, version, Mojang signer, completeness, and ABI, then installs it.

The saved session lives only under
`ports/minecraftbedrock-data/downloader/`, with private file permissions. Use
**Sign out of Google Play** to remove the session, or **Remove optional
downloader** to remove its browser, keyboard, and session while keeping APKs,
installed versions, and worlds. This is currently an RG34XXSP/Knulli prototype;
the Windows/WSL method below remains the supported fallback. An ARM32 choice on
the RG34XXSP downloads a set for transfer to an armhf target; it does not turn
the ARM64-only on-device browser into an armhf application.

## Recommended Windows method

### 1. Nothing to install by hand

The helper installs the Windows Subsystem for Linux and Ubuntu itself, from its
step 1 button — see step 3 below. There is no `wsl --install` to run, no
administrator PowerShell to find, and no Ubuntu username or password to create.

Should you prefer to install Ubuntu yourself, `wsl --install -d Ubuntu` still
works and the helper will simply find it. The helper accepts `Ubuntu` and
versioned names such as `Ubuntu-24.04`. If you deliberately use another Ubuntu
name, set `MCBEDROCK_WSL_DISTRO` before starting
the helper.

### 2. Download and verify the helper

Download and extract:

[mcbedrock-get-windows-v2.0.0-rc.4.zip](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/mcbedrock-get-windows-v2.0.0-rc.4.zip)

Compare its SHA-256 with the release's
[SHA256SUMS.txt](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases/download/v2.0.0-rc.4/SHA256SUMS.txt):

```powershell
Get-FileHash -Algorithm SHA256 .\mcbedrock-get-windows-v2.0.0-rc.4.zip
```

PyInstaller executables are sometimes flagged by antivirus heuristics. Do not
allow a blocked file unless its hash matches the published release checksum.

### 3. Set it up and sign in

Run `mcbedrock-get.exe` and press the button in **step 1**. It performs whatever
is still missing and reports progress in the window:

1. Switches on the Windows Subsystem for Linux. Windows shows its own
   administrator prompt; approve it. If Windows asks to restart, restart and
   reopen the helper — it carries on from where it stopped.
2. Installs Ubuntu (~500 MB download, ~1.5 GB on disk).
3. Builds `gplaydl` inside it (~2 GB of build tools, a few minutes).

**Before installing anything it states that it is putting a complete Ubuntu
Linux system inside Windows**, with the sizes above and the removal command.
Read that panel; it is also available any time from **What gets installed?**.

Nothing has to be typed into a terminal, and no Linux username or password is
created: the helper works as root, which Windows permits without one, and
installs Ubuntu with `--no-launch` so its first-run wizard never appears.

Press the button again when it reads **Sign in…**, and complete Google's own
sign-in page with the account that owns Minecraft. It asks for the address and
password there; the helper never reads the password, and takes the address from
the finished session rather than asking for it twice.

The Windows account token is stored in
`%LOCALAPPDATA%\mcbedrock-getccount.json`; gplaydl keeps its session inside
Ubuntu under `/root/.local/share/mcbedrock-get/`. Pressing **Sign out** removes
both copies. If Ubuntu is unavailable it clears Windows first and tells you to
run Sign out again after WSL starts. Nothing is uploaded by this project.

To remove Ubuntu and everything the helper put in it:

```text
wsl --unregister Ubuntu
```

### 4. Choose an architecture and version

Leave **64-bit arm64-v8a** selected for RG34XX SP, RGDS, and most current
PortMaster devices. Select **32-bit armeabi-v7a** for an R36S-class device
whose firmware reports armhf. The helper replaces a previous same-version set
in the output folder so APKs from different architectures cannot be mixed.

The version list holds **every Bedrock build Google Play still serves** for the
selected architecture — several hundred of them — read from
[mcpelauncher-versiondb](https://github.com/minecraft-linux/mcpelauncher-versiondb)
and cached under `%LOCALAPPDATA%\mcbedrock-getersiondb\`. Scroll it, or type
in the search box. **Include beta & preview builds** adds the rest; **Refresh
list** re-reads it from GitHub.

The builds marked ★ **Tested** are the ones this port has actually been run on,
and they carry a note saying why you would pick each. Anything else is offered
as-is:

| Version | arm64 code | armhf code | Why |
|---|---:|---:|---|
| **1.16.221.01** | 971622101 | 951622101 | Recommended; best UI scaling and smoothest handheld experience |
| **1.21.51.01** | 972105101 | 952105101 | Newest tested original no-RenderDragon build |
| **1.16.40.02** | 943164002 | 941164002 | Early legacy-GLES build |
| **1.11.4.2** | — | 871110402 | Best measured no-GPU armhf build (7.03 fps) |

Google Play uses different version codes for each ABI even when the displayed
Minecraft version is identical. The helper selects the correct code; do not
substitute the arm64 code for an armhf request.

Offline, or if GitHub cannot be reached and nothing is cached yet, the list
falls back to the tested builds above, whose codes ship inside the helper.

The helper downloads into an isolated temporary directory, requires a base APK
and the selected `config.arm64_v8a` or `config.armeabi_v7a` split, then
publishes the complete set together. An old or partial download cannot be
mistaken for a new success.

Typical output:

```text
minecraft-971622101.apk
minecraft-971622101.config.arm64_v8a.apk
minecraft-971622101.config.en.apk
minecraft-971622101.config.xxhdpi.apk
minecraft-971622101.install_pack.apk
```

The exact language, density, and install-pack components can vary. Copy every
APK written for that version.

### 5. Copy the set to the handheld

Put every file from the selected download into:

```text
ports/minecraftbedrock-data/apk/
```

Launch **Minecraft Bedrock**, choose **Install APK**, select the detected set,
and wait for the progress screen to finish. The on-device installer verifies
package identity, version, signer, dependencies, and ABI again.

Do not use an x86/x86_64 download; it cannot run on the handheld. R36S/armhf
remains Best Effort until its complete physical release matrix is finished.

## Command line

The Windows executable also supports:

```text
mcbedrock-get --check
mcbedrock-get --login you@example.com
mcbedrock-get --logout
mcbedrock-get --list --abi armhf
mcbedrock-get --download 1.16.221.01 --abi armhf --out D:\apk
```

## Troubleshooting

**Ubuntu is not installed in WSL.** Press the step 1 button and let the helper
install it. If several Ubuntu distributions exist, set `MCBEDROCK_WSL_DISTRO`
to the desired name shown by `wsl --list --quiet`.

**Windows asked to restart during setup.** Restart, then open the helper again
and press step 1 once more; it resumes from wherever it stopped.

**The WSL downloader is not installed.** Press the step 1 button and wait; the
build runs inside the window and takes a few minutes.

**Play offers Minecraft for sale.** Sign out and use the Google account that
owns the Google Play Android edition.

**No matching ABI split was returned.** The helper rejects a result without
the selected `config.arm64_v8a` or `config.armeabi_v7a` file. Retry once; if it
repeats, include the version code, selected ABI, and helper error in an issue,
but never attach the APKs or account data.

**The port rejects the files.** Copy every APK from one version download. Do
not combine different dates, architectures, or version codes.

**The download times out.** Confirm WSL has network access, rerun the one-time
setup, and try again. A failed attempt leaves any previously complete set
unchanged.

## Building the helper from source

From `tools/mcbedrock-get/` on Windows with Python 3.11:

```text
build.bat
```

The build pins its direct dependencies and PyInstaller, generates notices from
the installed environment, and creates the versioned Windows release ZIP.
`wsl-setup.sh` builds the current upstream gplaydl source inside Ubuntu; no
Minecraft content enters the executable or repository.
