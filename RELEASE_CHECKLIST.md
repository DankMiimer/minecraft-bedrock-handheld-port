# Release checklist

The canonical package tree is `portmaster/minecraftbedrock/`; RGDS stable
helpers live in `bottomscreen/release/`. Do not release from `staging/`, device
dumps, or extracted archives.

Before tagging:

1. Update the single `VERSION` source and compatibility registry, then run
   `python3 scripts/generate_compat_docs.py`.
2. Build pinned arm64/armhf clients, RGDS companions, and the context bridge
   with the checked-in container recipes.
3. Run `bash tests/run_all.sh` and record the physical acceptance matrix. A
   testing prerelease may retain explicitly disclosed pending R36S/RGDS rows;
   stable publication requires every blocking physical matrix session.
   Confirm 1.16.221.01 remains the recommended default, the original
   1.21.51.01 matches its registered no-RenderDragon library SHA-256, and an
   unknown/reuploaded 1.21.51.01 is visibly marked not recommended.
   On RGDS, transition from a mapped local world to a LAN-hosted world and
   confirm cached terrain/waypoints disappear, live coordinates continue,
   `REMOTE WORLD / MAP UNAVAILABLE` is shown, and the terrain worker remains
   paused until a local world is loaded again.
   Exercise both IPv4 and IPv6 LAN paths. For a local world, switch worlds
   without moving and confirm the open LevelDB is selected immediately; verify
   touch on the physical bottom panel before and after repeated SELECT swaps.
   Exercise all five companion tabs, verify health/hunger snapshots update,
   verify Chat/Items never replace their content with game pixels, the Items
   source/destination gesture stays local, and the Chat touch keyboard opens.
4. Build both editions with `scripts/build_releases.py` twice and require
   identical SHA-256 values.
5. Run `scripts/check_release_safety.py` on standard, RGDS, and source
   archives. Inspect SBOMs and confirm no APKs, game libraries/assets, worlds,
   profiles, credentials, analysis dumps, device backups, or debug binaries.
6. Confirm the standard archive contains no telemetry, companion, minimap,
   dual-touch, OSK supervisor, or RGDS helper; confirm the RGDS archive is
   arm64-only and its client and companion both contain the `mcpe_companion`
   marker. Confirm neither RGDS binary contains the legacy mirror writer/blit.
7. Verify the exact release-index edition, channel, size, SHA-256, and minimum
   updater version for every asset.
8. Build the pinned Windows helper, run its unit tests and `--help` smoke test,
   and package the EXE, WSL setup script, shortcut script, README, and generated
   notices as `mcbedrock-get-windows-v$VERSION.zip`. Scan that bundle for
   forbidden Minecraft content and publish its SHA-256. It must appear in
   `SHA256SUMS.txt` but never in a port archive or `release-index.json`, because
   the index is consumed only by the on-device edition updater.
9. Confirm `README.md`, the packaged README, and
   `GETTING-BEDROCK-APKS.md` agree on edition names, shared APK path, ABI,
   recommended version, Windows bundle name, and legal disclaimer. Validate
   every local link and every release-asset URL.

Publish stable/testing assets only after their required gates pass. Keep code
rollback directories and migration recovery manifests until the first clean
launch on each migrated installation.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT. No game files are included.**
