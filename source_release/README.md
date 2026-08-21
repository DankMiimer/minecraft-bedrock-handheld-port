# Modified mcpelauncher source (GPL source offer)

No game files are included. This archive contains only launcher/runtime source,
patches, build recipes, tests, and licensing material.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.**

The `mcpelauncher-client` binary shipped with this port is built from the
minecraft-linux project with the modifications in these patch files:

| Patch | Applies to | Base commit |
|---|---|---|
| `game-window.patch` | https://github.com/minecraft-linux/game-window | `1777cab` |
| `libc-shim.patch` | https://github.com/minecraft-linux/libc-shim | `e40f8fe` |
| `linux-gamepad.patch` | https://github.com/MCMrARM/linux-gamepad | `68d75a7` |
| `mcpelauncher-client.patch` | https://github.com/minecraft-linux/mcpelauncher-client | `4c5f4fd` |
| `mcpelauncher-manifest-gitlinks.patch` | https://github.com/minecraft-linux/mcpelauncher-manifest | `368e38b` |

Exact base commits: `COMMITS.txt`. The output binary and every build-input hash
are recorded in `minecraftbedrock/bin/mcpelauncher-client.buildinfo`.

Earlier revisions are also published as branch `rg34xxsp-port` on these forks.
For this checkpoint, the pinned commits plus the patch files in this source
bundle are the authoritative and reproducible source inputs:

- https://github.com/DankMiimer/mcpelauncher-manifest/tree/rg34xxsp-port
- https://github.com/DankMiimer/mcpelauncher-client/tree/rg34xxsp-port
- https://github.com/DankMiimer/game-window/tree/rg34xxsp-port
- https://github.com/DankMiimer/libc-shim/tree/rg34xxsp-port
- https://github.com/DankMiimer/linux-gamepad/tree/rg34xxsp-port

## Building

Pinned Debian bookworm container, Clang cross-compiling to aarch64:

1. `build/clients/Dockerfile` selects the immutable Debian image and package
   snapshot.
2. `build/clients/build-in-container.sh` checks out every commit above,
   validates/applies the patches, and configures with:
   `-DGAMEWINDOW_SYSTEM=EGLUT -DBUILD_UI=OFF -DENABLE_QT_ERROR_UI=OFF
   -DUSE_OWN_CURL=ON -DCMAKE_BUILD_TYPE=Release`
   using `clang/clang++ --target=aarch64-linux-gnu`.
3. Build/export with:

   ```sh
   docker buildx build --build-arg TARGET_ARCH=aarch64 \
     --build-arg EDITION=standard --target export \
     --output type=local,dest=out -f build/clients/Dockerfile .
   ```

The EGLUT context hand-off uses the exported
`crusty_gamewindow_context_v1(1, active)` API supplied by the matching
`crusty-context-v1` runtime module. It does not read Westonpack private data
addresses. See `CRUSTY_CONTEXT_API.md` for the contract and failure rules.

This directory must accompany any public release of the port zip (or be
published at a URL linked from the release) to satisfy the GPL.
