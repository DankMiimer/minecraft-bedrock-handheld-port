# mcbedrock-get for Windows

Download your own Google Play copy of Minecraft Bedrock in the split-set format
required by the handheld port. The window lists **every version Google Play
still serves** for the architecture you pick — several hundred builds, scrollable
and searchable — with the handful this port has actually been tested on marked
and annotated.

**No game files are included.** Google Play must confirm that the signed-in
account owns Minecraft before gplaydl returns anything.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

## Use

1. Run `mcbedrock-get.exe`.
2. Press the button in **step 1**. It does whatever is still missing — switching
   on the Windows Subsystem for Linux, installing Ubuntu, building the
   downloader — and tells you first exactly what that involves.
3. Press it again when it says **Sign in…**, and complete Google's own page
   with the account that owns Minecraft. The helper never sees your password.
4. Choose your architecture, pick a version, press **Download**.
5. Copy every downloaded APK to `ports/minecraftbedrock-data/apk/` on the
   handheld, then choose **Install APK** in the port.

There is nothing to type into a terminal, no administrator PowerShell to find,
and no Linux username or password to invent. The only unavoidable interruption
is Windows' own administrator prompt when the Subsystem for Linux is switched
on, and a restart if Windows asks for one — reopen the helper afterwards and it
carries on from where it stopped.

## This installs Ubuntu Linux inside Windows

Worth being blunt about, because it is a whole operating system and not a small
library. **Step 1 says all of this before it installs anything.**

Google Play only hands Minecraft to a Play client, and the only one that still
works — gplaydl, from minecraft-linux/Google-Play-API — is Linux software.
Windows cannot run it, so the helper installs Linux to run it in.

| What | Size | Notes |
|---|---|---|
| Windows Subsystem for Linux | Windows component | Needs administrator once, and possibly a restart |
| Ubuntu Linux | ~500 MB download, ~1.5 GB on disk | A real distribution, in a lightweight VM |
| Build tools and gplaydl | ~2 GB, a few minutes | Compiled from source inside Ubuntu |

Ubuntu starts only when something uses it and stays on the machine until it is
removed. Other programs can use it too. To remove it completely:

```text
wsl --unregister Ubuntu
```

Everything the helper runs inside the distribution runs as **root**, which
Windows permits without a password. That is why no Linux account is ever
created: `wsl --install` is passed `--no-launch` so its first-run wizard, whose
only job is to invent a username and password, never appears. An install made
by an older version of this helper under a normal user's home is adopted rather
than rebuilt.

## Choosing a version

The list is read from
[mcpelauncher-versiondb](https://github.com/minecraft-linux/mcpelauncher-versiondb)
and cached under `%LOCALAPPDATA%\mcbedrock-get\versiondb\` for a day;
**Refresh list** re-reads it. Release builds are shown by default and
**Include beta & preview builds** adds the rest. With no network and no cache
yet, the list falls back to the tested builds, whose codes ship inside the
helper.

Every row states which edition it is, the named update it belongs to, and
whether it uses RenderDragon:

- **Pocket Edition** (below 1.2) is a different, older game, and it has **touch
  controls only** — a handheld's buttons do nothing in it.
- **RenderDragon** builds are guaranteed to stutter on this hardware. On Android
  that means **1.18.30 and newer**, not 1.17: RenderDragon shipped platform by
  platform (Xbox 1.13, PS4 1.14, Windows 10 1.16.200) and reached Android last,
  after being toggled on and off through the 1.17.40, 1.18.10 and 1.18.20 betas.
  The one exception is **1.21.51.01**, the original Android release of
  December 9 2024, which shipped with RenderDragon disabled for arm64 by
  mistake — armhf was unaffected and kept it. Two days later Mojang re-uploaded
  Android as **1.21.51.02** with it switched back on. Those are two separate
  builds with two separate Play codes (972105101 and 972105102), so asking for
  one gets exactly that one.
  ([minecraft.wiki/w/RenderDragon](https://minecraft.wiki/w/RenderDragon),
  [Bedrock Edition 1.21.51](https://minecraft.wiki/w/Bedrock_Edition_1.21.51))
- Everything above 1.16.221.01 draws a **tiny UI** on a handheld screen.

Rows marked ★ **Tested** are the ones this port has been run on:

| Version | arm64 code | armhf code | Purpose |
|---|---:|---:|---|
| 1.16.221.01 | 971622101 | 951622101 | Recommended; best handheld UI scaling |
| 1.21.51.01 | 972105101 | 952105101 | Newest no-RenderDragon build (arm64 only; the armhf build of the same version does have it) |
| 1.16.40.02 | 943164002 | 941164002 | Early legacy-GLES build |
| 1.11.4.2 | — | 871110402 | Best measured no-GPU armhf build (7.03 fps) |

Google Play uses a different version code per ABI for the same displayed
version, and the encoding changed by era, so codes are always looked up rather
than derived. Anything not marked ★ is offered as-is: it will download, but
nobody has run it on a handheld.

The helper requires a base APK and the matching `config.arm64_v8a` or
`config.armeabi_v7a` split before publishing the result — except for
pre-App-Bundle builds (roughly 1.12 and older), which ship as one APK carrying
`lib/<abi>/` inside, and are accepted once that library is confirmed present.
Choose `arm64-v8a` for most handhelds and `armeabi-v7a` for a 32-bit R36S-class
armhf firmware. The command-line equivalent is `--abi arm64` (the default) or
`--abi armhf`.

## Account data

The Windows token is stored at
`%LOCALAPPDATA%\mcbedrock-get\account.json`. The cached version list sits
beside it in `versiondb\` and holds no account data. gplaydl keeps a second session
cache under `/root/.local/share/mcbedrock-get/` inside Ubuntu. **Sign out** removes
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
mcbedrock-get --list --abi armhf          # add --all for beta builds
mcbedrock-get --login
mcbedrock-get --logout
mcbedrock-get --download 1.16.221.01 --out D:\apk
```

`--download` accepts any version `--list` prints, not just the tested ones.
`--refresh` re-reads the version list from GitHub instead of the saved copy.
`--login` only needs an address (`--login you@example.com`) if the helper could
not read one back from the completed sign-in.

Set `MCBEDROCK_WSL_DISTRO` when the intended Ubuntu distribution has a custom
name. Without the override, the helper prefers `Ubuntu`, then a versioned
`Ubuntu-*` installation.

## How it works

- `catalog.py` merges the two versiondb ABI files into one list, attaches the
  notes for the tested builds, and falls back to those builds alone when GitHub
  cannot be reached.
- `signin.py` opens Google's Embedded Setup page, exchanges its one-time cookie
  for the account token needed by gplaydl, and asks Google which account that
  session belongs to.
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
