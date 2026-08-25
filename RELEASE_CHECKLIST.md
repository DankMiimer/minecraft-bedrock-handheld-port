# Release checklist

The canonical package tree is `portmaster/minecraftbedrock/`; RGDS stable
helpers live in `bottomscreen/release/`. Do not release from device dumps or
extracted archives.

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
10. **Install the built archive on every reachable reference device before
    publishing, not after.** Extract the actual zip — not a deployed code tree
    — run **Self test** on each device, and record its summary line in the
    release notes. Any device that could not be included is named in the notes
    as excluded rather than left to be inferred. rc.14 was published without
    ever being installed on muOS because the card had died; the notes disclosed
    it, which was honest and backwards. Ten minutes here would have caught the
    rc.12 false "Weston runtime missing" warning before players saw it.

Publish stable/testing assets only after their required gates pass. Keep code
rollback directories and migration recovery manifests until the first clean
launch on each migrated installation.

## After publishing

1. **Set the release as Latest, and confirm it.** `releases/latest` is what the
   repository's own release page and every deep link resolve to. Every
   prerelease must carry the prerelease flag or GitHub hands that badge to the
   newest tag that does not — which is how rc.9 held it while rc.10 through
   rc.15 were published behind it.
2. **Commit the built `release-index.json` to `main`.** The on-device updater
   fetches it from `raw.githubusercontent.com/<repo>/main/release-index.json`,
   so the file in the repository is the published index — the copy inside the
   build artifact has no effect until it is committed. Do not hand-edit it:
   the build emits both channels' rows already, because a stable build is run
   with `--mirror-channel testing`. A fresh install defaults to `stable`, so a
   stable row is required or **Update port** fails for everyone who never
   changed the setting; the mirrored testing row carries existing testers onto
   the same asset instead of stranding them on the last release candidate.
   Check before committing that there is exactly one row per edition-and-channel
   pair — `release_select.py` fails on anything else — and that each pair's
   two rows carry the same asset, URL and SHA-256.
3. Download every published asset and verify its SHA-256 against
   `SHA256SUMS.txt` before committing the index that points at it.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
MOJANG OR MICROSOFT. No game files are included.**
