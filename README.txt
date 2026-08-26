Minecraft Bedrock for PortMaster - maintainer summary
=====================================================

Current end-user instructions are in README.md.

This repository builds two products from one shared, versioned core:

* minecraftbedrock-standard-vX.Y.Z.zip
  Lightweight single-screen PortMaster package for arm64 and armhf.
* minecraftbedrock-rgds-vX.Y.Z.zip
  Separate arm64 RGDS dual-screen package, shipped as EXPERIMENTAL. The
  second-screen companion is early development with one reference device
  (an RG DS on ROCKNIX/Sway) behind it; other RGDS environments are
  unsupported. Its edition.json declares stability=experimental and the
  launcher announces it at startup.

The current source version is in VERSION. Release manifests, archive names,
release notes, checksums, SPDX SBOMs, and release-index entries are generated
from it by scripts/build_releases.py.

Canonical source
----------------

* portmaster/minecraftbedrock/       shared launcher and standard package
* bottomscreen/release/              stable RGDS-only release overlay
* bottomscreen/{bottomd,bedrockmap,telemetry}/
                                     RGDS companion source
* source_release/                    launcher patches and exported context API
* build/{clients,companions}/        pinned container build recipes
* scripts/ and tests/                release tooling and automated gates

Root-level legacy launchers, device dumps, MCPE_versions, exported_apks,
eglut_build outputs, scratchpad material, and bottom-screen analysis data are
historical, generated, or private inputs. They are not package sources and the
release safety checks reject them.

Data and editions
-----------------

Both editions share only:

  $PORTS/minecraftbedrock-data/{apk,versions,profiles,backups}

Edition configuration, logs, runtime state, caches, and update channels remain
separate. Existing installs are migrated transactionally with a recovery
manifest, collision protection, compatibility links, and rollback retained
until the first clean launch.

Users must supply legally acquired official Mojang APKs. No game files, APKs,
credentials, analysis dumps, or DRM/license bypasses are distributed. Full
APKs and complete split sets are grouped by package, version, signer, splits,
and ABI before atomic extraction. PairIP/new-ABI 1.26 packages are rejected
before installation.

Compatibility
-------------

Host support is capability-selected rather than inferred from brittle OS or
CPU-core-name heuristics. The resolver covers Wayland/Sway, Mesa KMSDRM, H700
proprietary Mali/Weston, and X11 fallback paths, plus display modes, audio,
controller, touch, permissions, and active resolution.

Firmware scope for 2.0: Knulli, muOS and ROCKNIX each have a physical
reference device. The ArkOS family (ArkOS, dArkOS, DarkOS RE) does not and
never has, so it is out of scope for this release -- its code paths ship
unverified, mcpe_cfw_support() reports them as such, and docs/CFW-CONTRACTS.md
marks every clause assumed.

Compatibility labels are evidence based:

* Validated: passed the physical reference matrix.
* Best effort: admitted by a tested capability/backend path but not physically
  validated on that exact device/version.
* Unsupported: a known ABI, PairIP, graphics, or runtime incompatibility.

Bedrock 1.16.221.01 is the recommended/default version because its UI scaling
works best on handheld displays. The exact original 1.21.51.01 native library
registered in the compatibility database is the newest tested no-RenderDragon
arm64 build. Unknown 1.21.51.01 reuploads are warned and not recommended; the
version string alone is not used to infer renderer behavior.

The RGDS terrain minimap reads local-world LevelDB data. During LAN client
play, Bedrock does not retain the host's terrain database locally, so the
current companion clears any prior map and displays REMOTE WORLD / MAP
UNAVAILABLE while keeping live position and status telemetry. It never reuses
another world's terrain.

Locally produced artifacts are not a claim of completed physical validation.
2.0.1 is published from CI-built, twice-compared archives that were installed
and self-tested on every reachable reference device first; anything that could
not be verified that way says so in TESTING.md rather than being implied by the
version number. It carries one fix over 2.0.0: on ROCKNIX every on-screen
message went to the log alone, so the port could stop for a reason it had
already worked out and say nothing. See portmaster/minecraftbedrock/README.md
and COMPATIBILITY.md for the user-facing contract.

Build and verify
----------------

Run the automated host suite:

  bash tests/run_all.sh

Pinned cross-builds are defined in build/clients/Dockerfile and
build/companions/Dockerfile. The GitHub workflow builds all three client
targets, the RGDS companions, assembles both archives twice, and compares them
byte for byte. Stable publication remains gated on the documented physical
reference matrix.
