# PortMaster Submission Notes

Suggested first step: ask PortMaster maintainers for a quick legal/metadata
sanity check before opening a PR, because this port uses user-supplied Android
APK extraction.

Suggested Discord/testing message:

```text
I have an unofficial Minecraft Bedrock Edition port for aarch64 handhelds using
the minecraft-linux mcpelauncher project plus a custom EGLUT/Weston backend.

No Minecraft game files are included. Users must provide their own legally
obtained arm64 Bedrock APK; the first launch extracts it locally on-device.
The package includes launcher scripts, open-source support libraries, license
texts, and GPL source patches/source links for the modified launcher binary.

Tested on RG34XX-SP/Knulli and RG DS/ROCKNIX. It is marked not ready-to-run,
availability paid, experimental, aarch64 only, and uses weston_pkg_0.2.

NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG
OR MICROSOFT.

Before I open a PR, is this acceptable for PortMaster in principle, and is the
title/metadata format acceptable?
```
