# Legal Notes

This repository distributes launcher scripts, support libraries, and modified
open-source launcher source/patches only.

No Minecraft APKs, extracted Minecraft game libraries, assets, worlds, or
other Mojang/Microsoft game files are included. Users must provide their own
legally obtained Minecraft Bedrock Edition for Android APK.

Users obtain Minecraft themselves, from their own Google Play purchase, using
the minecraft-linux launcher; see `GETTING-BEDROCK-APKS.md`. Nothing in this
repository mirrors, hosts, or redistributes game files, and no tool here
defeats a protection measure or provides any way to obtain Minecraft without
owning it. APKs a user downloads are their own copy and must not be
redistributed.

Both downloaders -- the optional on-device one and the `tools/mcbedrock-get/`
helper -- follow three binding rules: they stay strictly open source, they
hardcode no bypass or cracked licence, and they never store or transmit account
credentials through a third-party server. `DOWNLOADER-POLICY.md` states them in
full and `scripts/check_downloader_policy.py` enforces them on every push.

The optional `tools/mcbedrock-get/` Windows helper is published as a separate
bundle. It contains no Minecraft code or assets. It uses the account holder's
Google sign-in token locally to drive minecraft-linux's gplaydl inside WSL;
Google Play still enforces ownership. The token is stored only on the user's
Windows/WSL installation. Sign out removes both caches when Ubuntu is
available, or clearly asks the user to rerun it after WSL starts.

Do not use this repository, issues, discussions, releases, or linked materials
to request, offer, mirror, or distribute Minecraft APKs or extracted game
files. Do not upload logs or attachments containing private worlds, account
data, APK contents, or extracted `com.mojang` game data.

NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT.

Minecraft is owned by Mojang Studios and Microsoft. The launcher components
and bundled libraries are covered by their respective licenses; see the
release package and `source_release/` for details.

This project is not legal advice. If you are unsure whether you can use an APK
or share a derived artifact, do not share it publicly.
