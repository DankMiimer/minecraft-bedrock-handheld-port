#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/portmaster/minecraftbedrock/minecraftbedrock/lib/performance.sh"

unset MCPE_ARM64_HANDHELD_PRESET MCPE_MAX_FPS MCPE_RENDER_DISTANCE MCPE_VSYNC MCPE_UI_DENSITY_SCALE
mcpe_apply_arm64_defaults armhf
[ -z "${MCPE_ARM64_HANDHELD_PRESET:-}" ]

mcpe_apply_arm64_defaults arm64
[ "$MCPE_ARM64_HANDHELD_PRESET" = 1 ]
[ "$MCPE_MAX_FPS" = 40 ]
[ "$MCPE_RENDER_DISTANCE" = 80 ]
[ "$MCPE_VSYNC" = 0 ]
[ "$MCPE_UI_DENSITY_SCALE" = 2 ]

MCPE_MAX_FPS=60 MCPE_RENDER_DISTANCE=128 MCPE_VSYNC=1 MCPE_UI_DENSITY_SCALE=3
mcpe_apply_arm64_defaults arm64
[ "$MCPE_MAX_FPS" = 60 ]
[ "$MCPE_RENDER_DISTANCE" = 128 ]
[ "$MCPE_VSYNC" = 1 ]
[ "$MCPE_UI_DENSITY_SCALE" = 3 ]

unset MCPE_R36S_PERFORMANCE_PRESET MCPE_MAX_FPS MCPE_RENDER_DISTANCE MCPE_VSYNC
mcpe_apply_r36s_defaults arm64
[ -z "${MCPE_R36S_PERFORMANCE_PRESET:-}" ]

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
grep -qx 'gfx_max_framerate:40' "$ARM64_OPTIONS"
grep -qx 'ctrl_swap_gamepad_ab_buttons:0' "$ARM64_OPTIONS"
[ -f "$ARM64_OPTIONS.mcpe-arm64-handheld-v1" ]

# The preset is one-time: later in-game choices remain user-owned.
sed -i 's/^gfx_fancygraphics:.*/gfx_fancygraphics:0/' "$ARM64_OPTIONS"
mcpe_apply_arm64_game_options "$ARM64_OPTIONS" "$ARM64_PRESET"
grep -qx 'gfx_fancygraphics:0' "$ARM64_OPTIONS"

echo "performance profile tests passed"
