#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/performance.sh"

# --- Device memory tiers -------------------------------------------------------
# Boundaries sit between fittings, not on them: MemTotal is what the kernel has
# left after the firmware's carveouts, so a 2 GB device reports 1980 MB.
[ "$(mcpe_memory_tier 500)" = 512m ]     # R36S, measured
[ "$(mcpe_memory_tier 767)" = 512m ]
[ "$(mcpe_memory_tier 768)" = 1g ]
[ "$(mcpe_memory_tier 1000)" = 1g ]      # RG35XX-family 1 GB
[ "$(mcpe_memory_tier 1535)" = 1g ]
[ "$(mcpe_memory_tier 1536)" = 2g ]
[ "$(mcpe_memory_tier 1980)" = 2g ]      # RG34XX-SP, measured (2027140 kB)
[ "$(mcpe_memory_tier 2559)" = 2g ]
[ "$(mcpe_memory_tier 2560)" = 3g ]
[ "$(mcpe_memory_tier 3800)" = 3g ]
# A host that will not say must not be reclassified into a tier.
[ "$(mcpe_memory_tier 0)" = unknown ]
[ "$(mcpe_memory_tier notanumber)" = unknown ]
# An empty argument means "no argument": the host gets probed, as documented.

[ "$(mcpe_memory_mb 2027140)" = 1979 ]
[ "$(mcpe_memory_mb notanumber)" = 0 ]

# The budget is total minus a fifth, floored at 160 MB and capped at 512 MB.
[ "$(mcpe_memory_budget_mb 1980)" = 1584 ]   # 2 GB: 396 MB reserved
[ "$(mcpe_memory_budget_mb 1000)" = 800 ]    # 1 GB: the 200 MB fifth
[ "$(mcpe_memory_budget_mb 500)" = 340 ]     # 512 MB: the 160 MB floor
[ "$(mcpe_memory_budget_mb 4000)" = 3488 ]   # capped at 512 MB reserved
[ "$(mcpe_memory_budget_mb 200)" = 100 ]     # too small for the floor: half
[ "$(mcpe_memory_budget_mb 0)" = 0 ]

# The tier resolves before the ABI preset so its values are what that preset's
# ${VAR:-default} expansions see. 2 GB is the physically validated reference
# and must come out exactly as the port shipped it.
unset MCPE_RENDER_DISTANCE MCPE_TEXTURE_DEQUEUE MCPE_MAX_FPS MCPE_GAME_MEMORY_BUDGET_MB
MCPE_HOST_MEMORY_KB=2027140 mcpe_apply_memory_profile arm64
[ "$MCPE_MEMORY_TIER" = 2g ]
[ "$MCPE_RENDER_DISTANCE" = 80 ]
[ "$MCPE_TEXTURE_DEQUEUE" = 16 ]
[ "$MCPE_GAME_MEMORY_BUDGET_MB" = 1584 ]
mcpe_apply_arm64_defaults arm64
# No version given: the conservative modern cap, never the legacy one.
[ "$MCPE_MAX_FPS" = 30 ]
[ "$MCPE_RENDER_DISTANCE" = 80 ]

unset MCPE_RENDER_DISTANCE MCPE_TEXTURE_DEQUEUE MCPE_MAX_FPS MCPE_GAME_MEMORY_BUDGET_MB
MCPE_HOST_MEMORY_KB=524288 mcpe_apply_memory_profile arm64
[ "$MCPE_MEMORY_TIER" = 512m ]
[ "$MCPE_TEXTURE_DEQUEUE" = 2 ]
# 80 blocks is the engine's own floor; a smaller request is clamped back up.
[ "$MCPE_RENDER_DISTANCE" = 80 ]

unset MCPE_RENDER_DISTANCE MCPE_TEXTURE_DEQUEUE MCPE_GAME_MEMORY_BUDGET_MB
MCPE_HOST_MEMORY_KB=3221225 mcpe_apply_memory_profile arm64
[ "$MCPE_MEMORY_TIER" = 3g ]
[ "$MCPE_RENDER_DISTANCE" = 112 ]

# A caller's own choice outranks the tier.
unset MCPE_TEXTURE_DEQUEUE MCPE_GAME_MEMORY_BUDGET_MB
MCPE_RENDER_DISTANCE=200 MCPE_HOST_MEMORY_KB=524288 mcpe_apply_memory_profile arm64
[ "$MCPE_RENDER_DISTANCE" = 200 ]

# The armhf client keeps its own validated R36S profile.
unset MCPE_RENDER_DISTANCE MCPE_TEXTURE_DEQUEUE MCPE_GAME_MEMORY_BUDGET_MB
MCPE_HOST_MEMORY_KB=524288 mcpe_apply_memory_profile armhf
[ "$MCPE_MEMORY_TIER" = 512m ]
[ -z "${MCPE_TEXTURE_DEQUEUE:-}" ]
# ...but the budget is published on every ABI, because the client reads it.
[ "$MCPE_GAME_MEMORY_BUDGET_MB" = 352 ]

# An unreadable /proc/meminfo leaves the presets exactly as they were.
unset MCPE_RENDER_DISTANCE MCPE_TEXTURE_DEQUEUE MCPE_GAME_MEMORY_BUDGET_MB
MCPE_HOST_MEMORY_KB=0 mcpe_apply_memory_profile arm64
[ "$MCPE_MEMORY_TIER" = unknown ]
[ -z "${MCPE_RENDER_DISTANCE:-}" ]
[ -z "${MCPE_TEXTURE_DEQUEUE:-}" ]
[ -z "${MCPE_GAME_MEMORY_BUDGET_MB:-}" ]

unset MCPE_HOST_MEMORY_KB MCPE_MEMORY_TIER MCPE_HOST_MEMORY_MB
unset MCPE_RENDER_DISTANCE MCPE_TEXTURE_DEQUEUE MCPE_MAX_FPS MCPE_GAME_MEMORY_BUDGET_MB

unset MCPE_ARM64_HANDHELD_PRESET MCPE_MAX_FPS MCPE_RENDER_DISTANCE MCPE_VSYNC MCPE_UI_DENSITY_SCALE
mcpe_apply_arm64_defaults armhf
[ -z "${MCPE_ARM64_HANDHELD_PRESET:-}" ]

mcpe_apply_arm64_defaults arm64
[ "$MCPE_ARM64_HANDHELD_PRESET" = 1 ]
[ "$MCPE_MAX_FPS" = 30 ]
[ "$MCPE_RENDER_DISTANCE" = 80 ]
[ "$MCPE_VSYNC" = 0 ]
# Stock density: above 1 this only reaches Ore UI, where it made the
# Create New World and death screens overflow the panel.
[ "$MCPE_UI_DENSITY_SCALE" = 1 ]

MCPE_MAX_FPS=60 MCPE_RENDER_DISTANCE=128 MCPE_VSYNC=1 MCPE_UI_DENSITY_SCALE=3
mcpe_apply_arm64_defaults arm64
[ "$MCPE_MAX_FPS" = 60 ]
[ "$MCPE_RENDER_DISTANCE" = 128 ]
[ "$MCPE_VSYNC" = 1 ]
[ "$MCPE_UI_DENSITY_SCALE" = 3 ]

unset MCPE_R36S_PERFORMANCE_PRESET MCPE_MAX_FPS MCPE_RENDER_DISTANCE MCPE_VSYNC
mcpe_apply_r36s_defaults arm64
[ -z "${MCPE_R36S_PERFORMANCE_PRESET:-}" ]

# --- Version-keyed frame cap ---------------------------------------------------
# Dotted-numeric ordering, with absent components counting as zero.
mcpe_version_le 1.16.221.01 1.16.221.01
mcpe_version_le 1.14.60.5 1.16.221.01
mcpe_version_le 1.16 1.16.221.01
mcpe_version_le 1.16.221 1.16.221.01
mcpe_version_le 1.9.99.99 1.16.221.01          # 9 < 16, not a string compare
! mcpe_version_le 1.16.221.02 1.16.221.01
! mcpe_version_le 1.21.51.01 1.16.221.01
! mcpe_version_le 1.20 1.16.221.01
! mcpe_version_le 2.0 1.16.221.01

# 1.16.221.01 and older keep a cap high enough to stay responsive; newer builds
# take the one that stays binding, and therefore evenly paced, under load.
[ "$(mcpe_default_max_fps 1.16.221.01)" = 50 ]
[ "$(mcpe_default_max_fps 1.16.0.2)" = 50 ]
[ "$(mcpe_default_max_fps 1.14.60.5)" = 50 ]
[ "$(mcpe_default_max_fps 1.16.221.02)" = 30 ]
[ "$(mcpe_default_max_fps 1.20.62.02)" = 30 ]
[ "$(mcpe_default_max_fps 1.21.51.01)" = 30 ]
# Unknown or unparseable resolves to the conservative cap, never the legacy one.
[ "$(mcpe_default_max_fps)" = 30 ]
[ "$(mcpe_default_max_fps '')" = 30 ]
[ "$(mcpe_default_max_fps 1.16.221.01-971622101-arm64)" = 30 ]
[ "$(mcpe_default_max_fps notaversion)" = 30 ]

# The preset carries the version through to the cap...
unset MCPE_ARM64_HANDHELD_PRESET MCPE_MAX_FPS MCPE_RENDER_DISTANCE MCPE_VSYNC MCPE_UI_DENSITY_SCALE
mcpe_apply_arm64_defaults arm64 1.16.221.01
[ "$MCPE_MAX_FPS" = 50 ]

unset MCPE_MAX_FPS
mcpe_apply_arm64_defaults arm64 1.21.51.01
[ "$MCPE_MAX_FPS" = 30 ]

# ...and the player's own choice still outranks both.
unset MCPE_MAX_FPS
MCPE_MAX_FPS=90 mcpe_apply_arm64_defaults arm64 1.16.221.01
[ "$MCPE_MAX_FPS" = 90 ]
unset MCPE_MAX_FPS
MCPE_MAX_FPS=20 mcpe_apply_arm64_defaults arm64 1.21.51.01
[ "$MCPE_MAX_FPS" = 20 ]

# The split is arm64-only: armhf keeps its throughput-bound R36S cap.
unset MCPE_R36S_PERFORMANCE_PRESET MCPE_MAX_FPS MCPE_RENDER_DISTANCE MCPE_VSYNC
mcpe_apply_r36s_defaults armhf
[ "$MCPE_MAX_FPS" = 10 ]

mcpe_apply_r36s_defaults armhf
[ "$MCPE_R36S_PERFORMANCE_PRESET" = 1 ]
[ "$MCPE_MAX_FPS" = 10 ]
[ "$MCPE_RENDER_DISTANCE" = 32 ]
[ "$MCPE_VSYNC" = 0 ]

MCPE_MAX_FPS=30 MCPE_RENDER_DISTANCE=64 MCPE_VSYNC=1
mcpe_apply_r36s_defaults armhf
[ "$MCPE_MAX_FPS" = 30 ]
[ "$MCPE_RENDER_DISTANCE" = 64 ]
[ "$MCPE_VSYNC" = 1 ]

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPTIONS="$TMP/options.txt"
cat >"$OPTIONS" <<'EOF'
gfx_fancygraphics:1
gfx_raytracing:1
gfx_max_dequeued_textures_per_frame:16
unrelated_setting:keep
EOF
mcpe_apply_r36s_game_options "$OPTIONS"

grep -qx 'gfx_fancygraphics:0' "$OPTIONS"
grep -qx 'gfx_raytracing:0' "$OPTIONS"
grep -qx 'gfx_max_dequeued_textures_per_frame:2' "$OPTIONS"
grep -qx 'gfx_async_texture_loads:1' "$OPTIONS"
grep -qx 'camera_shake:0' "$OPTIONS"
grep -qx 'screen_animations:0' "$OPTIONS"
grep -qx 'unrelated_setting:keep' "$OPTIONS"
[ "$(grep -c '^gfx_fancygraphics:' "$OPTIONS")" = 1 ]

ARM64_OPTIONS="$TMP/arm64-options.txt"
ARM64_PRESET="$ROOT/portmaster/minecraftbedrock/minecraftbedrock/defaults/arm64-handheld-options.txt"
cat >"$ARM64_OPTIONS" <<'EOF'
mp_username:KeepMe
game_language:nb_NO
gfx_fancygraphics:0
gfx_viewdistance:32
ctrl_swap_gamepad_ab_buttons:1
EOF
mcpe_apply_arm64_game_options "$ARM64_OPTIONS" "$ARM64_PRESET"
grep -qx 'mp_username:KeepMe' "$ARM64_OPTIONS"
grep -qx 'game_language:nb_NO' "$ARM64_OPTIONS"
grep -qx 'gfx_fancygraphics:1' "$ARM64_OPTIONS"
grep -qx 'gfx_viewdistance:80' "$ARM64_OPTIONS"
# Only the first-launch seed. The launcher re-pins the cap from the
# version-keyed default on every run afterwards.
grep -qx 'gfx_max_framerate:30' "$ARM64_OPTIONS"
grep -qx 'ctrl_swap_gamepad_ab_buttons:0' "$ARM64_OPTIONS"
[ -f "$ARM64_OPTIONS.mcpe-arm64-handheld-v1" ]

# The preset is one-time: later in-game choices remain user-owned.
sed -i 's/^gfx_fancygraphics:.*/gfx_fancygraphics:0/' "$ARM64_OPTIONS"
mcpe_apply_arm64_game_options "$ARM64_OPTIONS" "$ARM64_PRESET"
grep -qx 'gfx_fancygraphics:0' "$ARM64_OPTIONS"

echo "performance profile tests passed"
