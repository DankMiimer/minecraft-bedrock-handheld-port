# mcbedrock-get — download your own Bedrock builds on Windows

Sign in with the Google account that owns Minecraft, press a version, get the
arm64 APKs for the handheld port. Two versions, no version hunting.

| Button | Version code | Why |
|---|---|---|
| 1.16.221.01 | 971622101 | Recommended — legacy UI scales properly on a small screen |
| 1.21.51.01 | 972105101 | Newest tested build without RenderDragon |

No Minecraft content is bundled with or distributed by this tool. It downloads
your own Play purchase, and only if Google confirms your account owns it.

## Use

1. Run **Create desktop shortcut.cmd** once for a desktop launcher.
2. Enter the email of the account that owns Minecraft → **Sign in…** →
   complete Google's page.
3. Press a version. The first time, it offers to install the downloader into
   WSL — say yes, enter your Ubuntu password in the terminal that opens, and
   wait a few minutes while it builds.
4. Press the version again. Files land in the chosen folder.
5. Copy **every** `.apk` from that folder to the device, into
   `ports/minecraftbedrock-data/apk/`, then use **Install APK** in the port.

A download is the base APK plus its splits, for example:

```text
minecraft-971622101.apk                    base
minecraft-971622101.config.arm64_v8a.apk   arm64 game code
minecraft-971622101.config.en.apk          language
minecraft-971622101.config.xxhdpi.apk      screen density
minecraft-971622101.install_pack.apk       assets, when present
```

They are one install. Copy the whole set; the port rejects partial sets.

## How it works

Google blocks third-party desktop Play clients — Raccoon died in early 2026,
apkeep refuses paid apps, and Python clients get `DF-DFERH-01`. The only client
still able to download Minecraft is minecraft-linux's, which is Linux software.
So this app splits the job between the two things that actually work:

- **`signin.py`** — Google's own sign-in page in an embedded browser, producing
  a long-lived account token. Runs in a child process, because the embedded
  browser needs the main thread and the window already holds it. No password is
  ever read by this tool; only the token Google issues, kept in
  `%LOCALAPPDATA%\mcbedrock-get\account.json`.
- **`wsl_backend.py`** — drives `gplaydl` from
  [minecraft-linux/google-play-api](https://github.com/minecraft-linux/google-play-api)
  inside WSL, writing straight into your Windows folder through `/mnt`. Its
  `--app-version` takes an arbitrary old version code, which is the whole reason
  old builds are reachable at all.
- **`wsl-setup.sh`** — one-time build of `gplaydl`, and writes the arm64
  `device.conf`. Only the ABI is overridden; every other device property keeps
  the upstream default, which is the identity Google currently accepts.

WSL is required, since the downloader is a Linux binary. Removing that would
mean porting google-play-api to MSVC.

## Build

```
build.bat
```

Produces `dist\mcbedrock-get.exe` plus its notices, the shortcut script and
`wsl-setup.sh`. Requires Python 3.10+; every dependency installs as a pure
wheel, so no compiler is needed.

One-file PyInstaller executables are routinely flagged by antivirus heuristics —
Windows Defender blocks this one on first run until allowed. Publish the SHA-256
that `build.bat` prints next to the download.

## Command line

```
mcbedrock-get --check                    report setup state
mcbedrock-get --login you@example.com    sign in only
mcbedrock-get --download 1.16.221.01 --out D:\apk
```

## Troubleshooting

**"The downloader is not installed in WSL yet."** Say yes to the setup prompt.
If the terminal reports an error it now stays open so you can read it.

**Play offers Minecraft for sale although you own it.** Wrong Google account, or
the purchase is on Xbox/Windows/Switch/Amazon — those are separate entitlements
and do not grant the Play Android app.

**The port rejects the set.** Something is missing. Copy every file whose name
starts with the same `minecraft-<code>` prefix, base APK included.

**A download produced no `config.arm64_v8a` file.** The tool refuses this case
rather than handing you an unusable set. Report it with the version code.
