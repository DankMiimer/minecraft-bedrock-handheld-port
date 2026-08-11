# mcbedrock-get for Windows

Download your own Google Play copy of Minecraft Bedrock in the arm64 split-set
format required by the handheld port. The tool offers the recommended
1.16.221.01 build and the fingerprinted original 1.21.51.01 build.

**No game files are included.** Google Play must confirm that the signed-in
account owns Minecraft before gplaydl returns anything.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Use

1. Install Ubuntu with `wsl --install -d Ubuntu` and reboot if prompted.
2. Run `mcbedrock-get.exe`.
3. Enter the Google email that owns Minecraft and complete Google's sign-in
   page. The helper never reads your password.
4. Press a version. On first use, accept the WSL setup and enter your Ubuntu
   password in the terminal while gplaydl is built.
5. Press the version again, then copy every downloaded APK to
   `ports/minecraftbedrock-data/apk/` on the handheld.
6. Choose **Install APK** in the port and wait for extraction to finish.

| Version | Play code | Purpose |
|---|---:|---|
| 1.16.221.01 | 971622101 | Recommended; best handheld UI scaling |
| 1.21.51.01 | 972105101 | Newest tested original no-RenderDragon arm64 build |

The helper requires a base APK and `config.arm64_v8a` split before publishing
the result. It does not provide `armeabi-v7a`; 32-bit R36S users should follow
the manual armhf instructions in the repository's `GETTING-BEDROCK-APKS.md`.

## Account data

The Windows token is stored at
`%LOCALAPPDATA%\mcbedrock-get\account.json`. gplaydl keeps a second session
cache under `~/.local/share/mcbedrock-get/` inside Ubuntu. **Sign out** removes
both. If Ubuntu is unavailable, it clears Windows first and tells you to run
Sign out again after WSL starts. No credential or APK is uploaded by this
project.

The WSL config is transferred over stdin, normalized to Linux line endings,
and stored with mode `0600`. The token is never placed in a Windows or Linux
process command line. rc.4 and newer use gplayver's non-interactive path;
rc.3's interactive path could loop until its five-minute timeout.

## Command line

```text
mcbedrock-get --check
mcbedrock-get --login you@example.com
mcbedrock-get --logout
mcbedrock-get --download 1.16.221.01 --out D:\apk
```

Set `MCBEDROCK_WSL_DISTRO` when the intended Ubuntu distribution has a custom
name. Without the override, the helper prefers `Ubuntu`, then a versioned
`Ubuntu-*` installation.

## How it works

- `signin.py` opens Google's Embedded Setup page and exchanges its one-time
  cookie for the account token needed by gplaydl.
- `wsl_backend.py` builds and drives gplaydl from
  [minecraft-linux/Google-Play-API](https://github.com/minecraft-linux/Google-Play-API)
  under WSL.
- Each download is isolated, validated for a base and arm64 split, then moved
  into the chosen Windows folder as one set.

The helper distributes no Minecraft code or assets. It is a local interface to
the account holder's Play entitlement.

## Build

Run `build.bat` with Python 3.11. It installs the pinned dependencies, builds
the one-file executable, generates authoritative third-party notices, and
creates `dist\mcbedrock-get-windows-vX.Y.Z.zip`.

PyInstaller executables can trigger antivirus heuristics. Release users should
verify the bundle against the SHA-256 published beside it before allowing a
blocked file.
