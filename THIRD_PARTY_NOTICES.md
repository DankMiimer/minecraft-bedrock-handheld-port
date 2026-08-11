# Third-Party Notices

This repository is a distribution wrapper around several upstream projects.

| Component | Source | License / notice |
|---|---|---|
| mcpelauncher-manifest / mcpelauncher-client | https://github.com/minecraft-linux | GPL-3.0 |
| game-window | https://github.com/minecraft-linux/game-window | MIT |
| eglut | https://github.com/minecraft-linux/eglut | MIT |
| libc-shim | https://github.com/minecraft-linux/libc-shim | part of the minecraft-linux launcher stack |
| linux-gamepad | https://github.com/MCMrARM/linux-gamepad | MIT |
| OpenSSL, libpng, libudev, libatomic | bundled in the release zip | license texts are included in `minecraftbedrock/licenses/` inside the release package |
| Monocraft font (menu) | https://github.com/IdreesInc/Monocraft | SIL OFL 1.1 (`minecraftbedrock/licenses/OFL-1.1-Monocraft.txt`) |

Release packages also include `source_release/`, which contains the exact patch
set and base/result commit list used for the distributed launcher binary.

## Windows helper (`tools/mcbedrock-get/`)

The helper is published as a separate Windows bundle and is licensed GPL-3.0
like the rest of this repository. Its corresponding source ships in the source
archive. It delegates entitled downloads to minecraft-linux/Google-Play-API's
gplaydl inside the user's WSL installation.

| Component | License |
|---|---|
| gpsoauth, urllib3, charset-normalizer, bottle, proxy_tools, pythonnet, clr_loader | MIT |
| cffi | MIT-0 |
| pywebview, idna, pycparser | BSD-3-Clause |
| requests | Apache-2.0 |
| pycryptodomex | BSD-2-Clause and public domain |
| certifi | MPL-2.0 |
| typing_extensions | PSF-2.0 |
| CPython runtime | PSF |

The dependency table is a convenience summary. Full licence texts are
generated from the exact pinned Windows build environment by
`tools/mcbedrock-get/gen_notices.py` and published as
`mcbedrock-get-NOTICES.txt` beside the executable. That file, not this table,
is authoritative for a given build.

Minecraft itself is owned by Mojang Studios and Microsoft. No Minecraft APKs,
extracted libraries, assets, worlds, or other game files are included.

NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.
