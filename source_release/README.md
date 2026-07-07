# Modified mcpelauncher source (GPL source offer)

The `mcpelauncher-client` binary shipped with this port is built from the
minecraft-linux project with the modifications in these patch files:

| Patch | Applies to | Base commit |
|---|---|---|
| `game-window.patch` | https://github.com/minecraft-linux/game-window | `1777cab` |
| `libc-shim.patch` | https://github.com/minecraft-linux/libc-shim | `e40f8fe` |
| `linux-gamepad.patch` | https://github.com/MCMrARM/linux-gamepad | `68d75a7` |
| `mcpelauncher-client.patch` | https://github.com/minecraft-linux/mcpelauncher-client | `4c5f4fd` |
| `mcpelauncher-manifest-gitlinks.patch` | https://github.com/minecraft-linux/mcpelauncher-manifest | `368e38b` |

Exact base/result commits: `COMMITS.txt`.

The same modified source is published as branch `rg34xxsp-port` on these
forks (a recursive clone of the manifest fork builds the port):

- https://github.com/DankMiimer/mcpelauncher-manifest/tree/rg34xxsp-port
- https://github.com/DankMiimer/mcpelauncher-client/tree/rg34xxsp-port
- https://github.com/DankMiimer/game-window/tree/rg34xxsp-port
- https://github.com/DankMiimer/libc-shim/tree/rg34xxsp-port
- https://github.com/DankMiimer/linux-gamepad/tree/rg34xxsp-port

## Building

Debian bookworm container, clang cross-compiling to aarch64:

1. `eglut_build/Dockerfile.deps` — build the dependency image
   (`mcpe-build:bookworm`).
2. Check out `mcpelauncher-manifest` at the base commit above with
   submodules, apply the patches.
3. Configure with:
   `-DGAMEWINDOW_SYSTEM=EGLUT -DBUILD_UI=OFF -DENABLE_QT_ERROR_UI=OFF
   -DUSE_OWN_CURL=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo`
   using `clang/clang++ --target=aarch64-linux-gnu`.
4. `make mcpelauncher-client` — see `eglut_build/_container_build.sh` /
   `_container_build_incr.sh` for the exact invocation.

These patches include changes that are specific to Westonpack 0.2.7.1
aarch64 (private crusty struct offsets in `game-window`) — see the port
README for details.

This directory must accompany any public release of the port zip (or be
published at a URL linked from the release) to satisfy the GPL.
