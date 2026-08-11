# Downloading your owned Bedrock APKs

This guide obtains **1.16.221.01** (recommended) or **1.21.51.01** for the
handheld port from your own Google Play purchase.

**No game files are included.** This project does not host APKs, bypass a
license check, or download Minecraft for an account that does not own it.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Before you start

- The Google account must own Minecraft on **Google Play**. Xbox, Windows,
  Switch, PlayStation, Amazon, and Samsung purchases are separate.
- The packaged Windows helper downloads `arm64-v8a` sets only. That is correct
  for most 64-bit handhelds, H700 devices, and RGDS.
- R36S/RK3326 users on 32-bit firmware need an `armeabi-v7a` set; see the
  manual armhf section below.

## Recommended Windows method

### 1. Install Ubuntu in WSL

Open PowerShell as administrator:

```powershell
wsl --install -d Ubuntu
```

Reboot if prompted, start Ubuntu once, and create its local username/password.
The helper accepts `Ubuntu` and versioned names such as `Ubuntu-24.04`. If you
deliberately use another Ubuntu name, set `MCBEDROCK_WSL_DISTRO` before starting
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

### 3. Sign in and install the downloader

Run `mcbedrock-get.exe`:

1. Enter the email of the Google account that owns Minecraft.
2. Press **Sign in** and complete Google's own sign-in page. The helper never
   reads your password.
3. Press a Download button. The first attempt offers a one-time WSL setup.
4. Accept it and enter your Ubuntu password in the terminal that opens. The
   setup builds `gplaydl` from minecraft-linux/Google-Play-API.
5. Close the terminal after it reports success and press Download again.

The Windows account token is stored in
`%LOCALAPPDATA%\mcbedrock-get\account.json`; gplaydl keeps its session inside
Ubuntu under `~/.local/share/mcbedrock-get/`. Pressing **Sign out** removes both
copies. If Ubuntu is unavailable it clears Windows first and tells you to run
Sign out again after WSL starts. Nothing is uploaded by this project.

Do not use the rc.3 helper: its interactive WSL authentication could loop at
**Passing your Google session to the downloader** until the five-minute
timeout. rc.4 transfers the same valid token privately over stdin and uses the
upstream non-interactive path.

### 4. Choose a version

| Button | Play version code | Why |
|---|---:|---|
| **1.16.221.01** | 971622101 | Recommended; best UI scaling and smoothest handheld experience |
| **1.21.51.01** | 972105101 | Newest tested original no-RenderDragon arm64 build |

The helper downloads into an isolated temporary directory, requires a base APK
and `config.arm64_v8a` split, then publishes the complete set together. An old
or partial download cannot be mistaken for a new success.

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

## Manual armhf route

The published helper intentionally offers only the physically tested arm64
downloads. For a 32-bit R36S/RK3326 setup, use the upstream minecraft-linux UI
inside Ubuntu WSL:

1. Follow the current [minecraft-linux installation guide](https://minecraft-linux.github.io/getting_started/index.html).
2. Start its developer view with `mcpelauncher-ui-qt -d` so old/unsupported
   variants can be selected.
3. Select Bedrock **1.16.221.01** and the **`armeabi-v7a`** Android variant.
4. Use the launcher's APK-only download option and copy the entire matching set
   to `ports/minecraftbedrock-data/apk/`.

Do not use an x86/x86_64 download; it cannot run on the handheld. R36S/armhf
remains Best Effort until its complete physical release matrix is finished.

## Command line

The Windows executable also supports:

```text
mcbedrock-get --check
mcbedrock-get --login you@example.com
mcbedrock-get --logout
mcbedrock-get --download 1.16.221.01 --out D:\apk
```

## Troubleshooting

**Ubuntu is not installed in WSL.** Run `wsl --install -d Ubuntu` from an
administrator PowerShell and reboot. If several Ubuntu distributions exist,
set `MCBEDROCK_WSL_DISTRO` to the desired name shown by `wsl --list --quiet`.

**The WSL downloader is not installed.** Press Download, accept the setup
prompt, and leave the terminal open until it says setup finished.

**Play offers Minecraft for sale.** Sign out and use the Google account that
owns the Google Play Android edition.

**No `config.arm64_v8a` file was returned.** The helper rejects the result.
Retry once; if it repeats, include the version code and helper error in an
issue, but never attach the APKs or account data.

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
