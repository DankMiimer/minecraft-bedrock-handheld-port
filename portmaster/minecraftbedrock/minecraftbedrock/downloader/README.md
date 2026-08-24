# Optional on-device APK downloader (RG34XXSP prototype)

This module downloads the user's own purchased Minecraft Android package
directly from Google Play. It is never started, downloaded, or signed in unless
the user chooses **Get APK from Google Play** in the port menu. Manual APK
installation remains fully supported.

Three rules bind this module: it stays strictly open source, it hardcodes no
credential and no workaround for Google Play's ownership check, and it never
stores or transmits account credentials through a third-party server.
`../../../../DOWNLOADER-POLICY.md` states them in full; `PROVENANCE.json`
(shipped binaries, pinned downloads, network allowlist) and
`credential-artifacts.txt` (every path that can hold account data) are the
manifests `scripts/check_downloader_policy.py` enforces them against.

Prototype support is gated to 64-bit H700 devices running Knulli, Batocera or
muOS. muOS joined on 2026-08-24, verified on an RG34XX-SP running 2601.0
JACARANDA -- the same hardware as the Knulli reference device.
The first use reuses a compatible launcher runtime already present on the device
or downloads a pinned 141 MiB upstream AppImage and extracts its Qt WebEngine
files (about 550 MiB). A pinned Debian Qt virtual-keyboard plugin provides text
entry. Mesa exposes GLX to XWayland: Knulli and Batocera already ship that
package through PortMaster, and where PortMaster does not carry it -- muOS has
an empty `libs/` -- the same pinned runtime is downloaded and verified against
`compat/runtime-index.json`, exactly as the Weston package already is. While
PortMaster's Weston/Crusty/GL4ES runtime presents the Qt interface through the
H700's OpenGL ES display stack. The bundled compatibility shim only bridges
Qt's XCB GLX capability probe; it does not implement or intercept rendering.

The Google password and phone approval are handled inside Google's embedded
sign-in page. The port only receives an approved long-lived Play token from the
upstream `minecraft-linux` launcher. Session files stay under the private
`minecraftbedrock-data/downloader/` directory with mode 0600/0700 and are not
written to logs. The menu's sign-out action removes them.

The port menu presents downloader actions as a two-column tile grid. Inside the
Google window, D-pad directions move keyboard focus, A activates the focused
tile/control, B goes back, and the shoulders page-scroll. The controller bridge
starts inside the Weston session after the Qt window exists and loads the port's
verified RG34XXSP SDL mapping. Focused text fields open Qt's on-screen keyboard.

After **Continue to Google sign-in**, a dedicated fullscreen LOVE surface
replaces LOVE's retained confirmation frame with a milestone progress panel. It reports the one-time
browser download/extraction, keyboard and graphics setup, saved-session check,
Google approval exchange, live `gplaydl` download percentage, and validation.
The downloader and progress surface use an acknowledgement handshake: LOVE
fully releases Mali before the interactive Weston/Qt Google window opens, then
the progress surface returns after Google closes. A tty panel remains only as a
fallback for environments where the graphical surface is unavailable.

The first page keeps the two recommended/tested arm64 downloads prominent. An
explicit **Other versions [EXPERIMENTAL]** tile opens a compact catalog of all
Google Play ARM64 and ARM32 entries in the port's declared 1.16-1.21 range:
110 ARM64 releases, 231 ARM64 previews/betas, 109 ARM32 releases, and 235 ARM32
previews/betas in the current snapshot. Up/down selects a build, left/right
switches architecture, and X switches release/preview channel. The catalog is
generated from the upstream architecture-specific version databases by
`scripts/update_gplay_version_catalog.py`; 1.26+ PairIP/new-ABI builds remain
excluded. Catalog builds are experimental unless explicitly labelled tested
and are never selected automatically. ARM32 downloads are for transfer to an
armhf R36S-class setup—the browser prototype itself still runs only on a
64-bit H700 host on Knulli, Batocera or muOS.

`bin/gplaydl` and `bin/gplayver` are ARM64 builds of
`minecraft-linux/Google-Play-API` commit
`6ead91313122b1b732854c29edfb40dbad4abac6` (Apache-2.0). Rebuild them with
`tools/ondevice-downloader/build-gplaydl-arm64.sh`; the corresponding license is
installed beside the binaries.

`lib/libqt-xcb-glx-compat.so` is built from the repository's small C source
with `tools/ondevice-downloader/build-qt-xcb-glx-compat-arm64.sh`.
