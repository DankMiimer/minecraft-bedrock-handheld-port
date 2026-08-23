# Bedrock compatibility registry

This file is generated from `minecraftbedrock/compat/compatibility.json`.

| Bedrock | ABI | Status | Renderer | Recommendation | Guards / notes |
|---|---|---|---|---|---|
| 1.16.40.02 | armhf | Best Effort | legacy_gles_no_renderdragon | Optional Smoke | older no-RenderDragon armhf anchor; physical release gate pending; the EduMode and HTTP-resolver guards are arm64-only code paths and cannot apply here, so the launcher forces offline startup instead |
| 1.16.221.01 | arm64 | Best Effort | legacy_gles_no_renderdragon | Recommended | edumode_guard; http_resolver_guard; recommended everyday build because its legacy UI scales cleanly on handheld displays; guarded patches, Mali rendering, active RG34 audio, RGDS live telemetry and companion startup, and forced-timeout restoration passed on RG34XX-SP/Knulli and RGDS/ROCKNIX; full acceptance remains pending |
| 1.16.221.01 | armhf | Best Effort | legacy_gles_no_renderdragon | Recommended | recommended armhf target for usable UI scaling; R36S KMSDRM validation required; the EduMode and HTTP-resolver guards are arm64-only code paths and cannot apply here, so the launcher forces offline startup instead |
| 1.17.41.01 | arm64 | Best Effort | renderdragon_or_unclassified | Optional Smoke | RenderDragon-era compatibility smoke only; not a 2.0 release gate because of severe handheld stutter; the HTTP-resolver guard is pinned to the arm64 1.16.221.01 binary and cannot apply here |
| 1.20.15.01 | arm64 | Best Effort | renderdragon_or_unclassified | Optional Smoke | RenderDragon-era compatibility smoke only; not a 2.0 release gate because of severe handheld stutter |
| 1.20.51.01 | arm64 | Best Effort | renderdragon_or_unclassified | Optional Smoke | assets: preserve_nested; RenderDragon-era compatibility smoke only; not a 2.0 release gate because of severe handheld stutter |
| 1.20.62.02 | arm64 | Best Effort | renderdragon_or_unclassified | Optional Smoke | optional: auto_compaction; assets: preserve_nested; guarded compaction signature matched and timed launch/cleanup passed on RG34XX-SP/Knulli; retained as an optional compatibility smoke, not a 2.0 release gate |
| 1.21.50.28 | arm64 | Best Effort | renderdragon_or_unclassified | Optional Smoke | RenderDragon-era compatibility smoke only; not a 2.0 release gate because of severe handheld stutter |
| 1.21.51.01 | arm64 | Best Effort | legacy_gles_no_renderdragon | Newest Tested No RenderDragon | assets: preserve_nested; library SHA-256: `45382be72491…`; limitation: RGDS terrain tiles are available for local worlds only; a LAN client has no local copy of the host LevelDB, so the companion preserves live telemetry but labels the remote terrain map unavailable and never displays cached terrain from another world; exact original-release native library: install, world load, gameplay, audio, clean exit, dual-screen telemetry, local-world minimap, swapping, controls, and touch passed on RG34XX-SP/Knulli and RGDS/ROCKNIX; newer UI scaling is less usable than 1.16.221.01 |
| 1.21.51.01 | arm64 | Best Effort | unclassified_reupload | Not Recommended | assets: preserve_nested; warning: This 1.21.51.01 native library does not match the tested original no-RenderDragon fingerprint. A later reupload enabled RenderDragon and may stutter badly; use 1.16.221.01 or the fingerprinted original release.; version-name-only classification is unsafe because the later reupload reused 1.21.51.01 with different renderer behavior |
| 1.26.32.2 | arm64 | Unsupported | new_android_abi | Not Recommended | PairIP/new Android ABI |

## Labels

- **Validated** — Passed the physical reference matrix.
- **Best Effort** — Uses a tested capability path but is not validated on this exact combination.
- **Unsupported** — Known ABI, licensing, graphics, or launcher incompatibility.

## Recommendations

- **Recommended** — Default everyday build with the best handheld UI scaling.
- **Newest Tested No RenderDragon** — Newest exact no-RenderDragon artifact tested on the physical arm64 matrix.
- **Optional Smoke** — Selectable for compatibility diagnostics but not a release gate.
- **Not Recommended** — Known or unclassified renderer variant that is not selected automatically.

## Default admission

- `1.16-1.21`: **Best Effort**
- `1.26+`: **Unsupported**: PairIP/new Android ABI requires legal upstream launcher support
