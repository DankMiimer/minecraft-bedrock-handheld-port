# Licenses

## Launcher (bin/mcpelauncher-client)

Built from the minecraft-linux project with the port modifications shipped in
the matching `minecraftbedrock-source-vX.Y.Z.zip` release asset (patch files
against the listed upstream commits):

| Component | Upstream | License |
|---|---|---|
| mcpelauncher-manifest / mcpelauncher-client | github.com/minecraft-linux | GPL-3.0 (`GPL-3.0.txt`) |
| game-window | github.com/minecraft-linux/game-window | MIT (`MIT-game-window.txt`) |
| eglut | github.com/minecraft-linux/eglut | MIT (`MIT-eglut.txt`) |
| libc-shim | github.com/minecraft-linux/libc-shim | part of minecraft-linux project |
| linux-gamepad | github.com/MCMrARM/linux-gamepad | MIT (`MIT-linux-gamepad.txt`) |

The complete corresponding source for the modified components is provided in
that matching source asset (GPL section 6).

## Bundled shared libraries (libs.aarch64/, from Debian bookworm)

| Library | License |
|---|---|
| libcrypto.so.3 / libssl.so.3 (OpenSSL 3) | Apache-2.0 (`Apache-2.0.txt`) |
| libpng16.so.16 | libpng/PNG Reference Library License (`libpng.txt`) |
| libudev.so.1 (systemd) | LGPL-2.1+ (`LGPL-2.1.txt`) |
| libatomic.so.1 (GCC runtime) | GPL-3.0 with GCC Runtime Library Exception |

## Menu (menu/)

| Component | Source | License |
|---|---|---|
| font_testo.ttf / font_titolo.ttf (Monocraft Regular / Bold) | github.com/IdreesInc/Monocraft | SIL OFL 1.1 (`OFL-1.1-Monocraft.txt`) |
| main.lua / conf.lua (LÖVE launcher menu) | this port (original; UI drawn procedurally, no image assets) | GPL-3.0 with the rest of the port scripts |

## Not included

Minecraft itself is © Mojang Studios / Microsoft. This package contains no
game files; you must supply your own legally obtained APK.

NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.
