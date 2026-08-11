# Downloading Bedrock APKs on Windows

How to download **1.16.221.01** (recommended) and **1.21.51.01** for the port,
using your own Google account.

You need a Google account that owns Minecraft **on Google Play**. A purchase on
Xbox, Windows, Switch, PlayStation, Amazon or Samsung's store will not work —
those are separate entitlements.

Google now blocks third-party desktop downloaders, so the one client that still
works is minecraft-linux's, which is Linux software — on Windows it runs through
WSL. The setup below is a one-time job of about ten minutes.

## The easy way

[`tools/mcbedrock-get/`](tools/mcbedrock-get/) wraps all of this in a small app:
sign in, press **Download 1.16.221.01** or **Download 1.21.51.01**, and the
arm64 APKs appear in a folder. It installs the downloader into WSL for you and
refuses any result missing the arm64 split, so you cannot end up with the x86
build by accident. You still need WSL installed (step 1 below).

The rest of this page is the manual route, useful if you prefer the launcher's
full version list or the app misbehaves.

---

## 1. Install WSL (once)

Open **PowerShell as administrator** and run, then reboot:

```bash
wsl --install
```

## 2. Install the launcher (once)

Open **Ubuntu** from the Start menu and paste these three commands:

```bash
curl -sS https://minecraft-linux.github.io/pkg/deb/pubkey.gpg | sudo tee /etc/apt/trusted.gpg.d/minecraft-linux-pkg.asc
```

```bash
echo "deb [arch=amd64] https://minecraft-linux.github.io/pkg/deb noble main" | sudo tee /etc/apt/sources.list.d/minecraft-linux-pkg.list
```

```bash
sudo apt update && sudo apt install -y mcpelauncher-manifest mcpelauncher-ui-manifest msa-manifest
```

## 3. Start it and sign in

```bash
wsl -d Ubuntu -- bash -lc mcpelauncher-ui-qt
```

Sign in with the Google account that owns Minecraft.

Startup prints `libEGL warning ...` messages. Ignore them — they are normal
under WSL and do not affect downloading.

## 4. Set the architecture to arm64

**This is the step people get wrong.** On a PC the launcher defaults to
downloading **x86**, which will not run on the handheld. Change the download
architecture to **`arm64-v8a`** before downloading anything.

(Use `armeabi-v7a` instead only if your device is 32-bit armhf.)

## 5. Download the two versions

In the version list, download:

| Version | Play version code (arm64) | Why |
|---|---|---|
| **1.16.221.01** | 971622101 | Recommended default — legacy UI scales properly on a small screen |
| **1.21.51.01** | 972105101 | Newest tested build without RenderDragon |

Do not download anything from the 1.26 line. The port rejects it.

## 6. Copy the files to your SD card

The downloads are here, reachable from Windows Explorer:

```text
\\wsl.localhost\Ubuntu\home\<your-username>\.local\share\mcpelauncher\apks
```

Each download is several files with random-looking names:

| File | What it is |
|---|---|
| `com.mojang.minecraftpe-main-XXXXXX.apk` | the base APK |
| `com.mojang.minecraftpe-config.arm64_v8a-XXXXXX.apk` | the arm64 game code |
| `com.mojang.minecraftpe-config.en-XXXXXX.apk` | language pack |
| `com.mojang.minecraftpe-config.xxhdpi-XXXXXX.apk` | screen density pack |
| `com.mojang.minecraftpe-install_pack-XXXXXX.apk` | asset pack, if present |

The suffixes are random, so group them **by date** — everything from the same
download shares a date. To list them by date:

```bash
wsl -d Ubuntu -- bash -lc "ls -la --time-style=+%Y-%m-%d ~/.local/share/mcpelauncher/apks/"
```

Copy one complete dated group onto the SD card, into:

```text
ports/minecraftbedrock-data/apk/
```

Then on the device: start the port, open **Install APK**, select the set, and
install it.

---

## If something goes wrong

**The game installs but will not start.** You copied the `x86` split instead of
`arm64_v8a`. Go back to step 4.

**The port refuses the set.** Something is missing or two downloads got mixed.
Copy one complete dated group again, including the `-main-` base APK. The
installer checks each APK's manifest and signature and rejects incomplete or
mismatched sets on purpose.

**Play offers Minecraft for sale even though you own it.** You are signed in
with the wrong Google account, or your purchase is not a Google Play one.

**You only see the newest version.** Make sure you are picking from the
launcher's version list, which offers old builds. A phone cannot do this —
Google Play on a phone only ever installs the current release, which is the
1.26 line the port rejects.

---

## For maintainers

`tools/mcbedrock-get/` is an unfinished Windows downloader built on the `gpapi`
Python Play client. Sign-in, the version list and the diagnostics work;
downloading does not, because Google refuses that client's 2019-era protocol
with `DF-DFERH-01`. This was confirmed not to be a configuration problem — a
device profile replicating minecraft-linux's exactly, including SDK 36 and a
current Play client version, fails identically. It is kept for `--diagnose` and
`--probe` and is not published as a release binary. Reviving it means replacing
its Play layer with
[minecraft-linux/google-play-api](https://github.com/minecraft-linux/google-play-api).
