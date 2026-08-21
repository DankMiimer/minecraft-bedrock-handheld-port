#!/bin/bash
# Physically validated defaults for the two launcher classes.  Keep the
# 512-MB armhf/R36S profile separate from the arm64 handheld profile: they
# require very different graphics budgets.

mcpe_apply_arm64_defaults() {
  local abi="${1:-}"
  [ "$abi" = arm64 ] || return 0

  export MCPE_ARM64_HANDHELD_PRESET=1
  export MCPE_MAX_FPS="${MCPE_MAX_FPS:-40}"
  export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-80}"
  export MCPE_VSYNC="${MCPE_VSYNC:-0}"
  export MCPE_UI_DENSITY_SCALE="${MCPE_UI_DENSITY_SCALE:-2}"
}

mcpe_apply_r36s_defaults() {
  local abi="${1:-}"
  [ "$abi" = armhf ] || return 0

  export MCPE_R36S_PERFORMANCE_PRESET=1
  export MCPE_MAX_FPS="${MCPE_MAX_FPS:-10}"
  # Bedrock 1.16 stores this value in blocks. It currently clamps 32 (two
  # chunks) back to its internal 80-block minimum, but retain the low request
  # so versions which accept it do not silently start at four chunks.
  export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-32}"
  export MCPE_VSYNC="${MCPE_VSYNC:-0}"
}

mcpe_pin_game_option() {
  local options_file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$options_file" 2>/dev/null; then
    sed -i "s#^${key}:.*#${key}:${value}#" "$options_file"
  else
    printf '%s:%s\n' "$key" "$value" >>"$options_file"
  fi
}

mcpe_apply_arm64_game_options() { # options_file preset_file
  local options_file="$1" preset_file="$2" marker key value
  [ -f "$options_file" ] || return 1
  [ -f "$preset_file" ] || return 1
  marker="${options_file}.mcpe-arm64-handheld-v1"
  [ -e "$marker" ] && return 0

  while IFS='=' read -r key value; do
    case "$key" in ""|\#*) continue ;; esac
    case "$key" in *[!A-Za-z0-9_]*) return 1 ;; esac
    case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
    mcpe_pin_game_option "$options_file" "$key" "$value" || return 1
  done <"$preset_file"
  printf 'preset=arm64-handheld-v1\n' >"$marker"
}

mcpe_apply_r36s_game_options() {
  local options_file="$1" key value
  [ -f "$options_file" ] || return 1

  # These are all accepted by the physically tested 1.16.221.01 armhf build.
  # Keep async loading and the multithreaded renderer enabled: disabling either
  # increases visible stalls or drops static chunk draws on the RK3326 stack.
  while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    mcpe_pin_game_option "$options_file" "$key" "$value"
  done <<'EOF'
gfx_fancygraphics=0
gfx_fancyskies=0
gfx_toggleclouds=0
gfx_smoothlighting=0
gfx_transparentleaves=0
gfx_bubble_particles=0
gfx_particleviewdistance=0
gfx_msaa=1
gfx_texel_aa_2=0
gfx_upscaling=0
gfx_raytracing=0
gfx_async_texture_loads=1
gfx_max_dequeued_textures_per_frame=2
gfx_hidepaperdoll=1
gfx_viewbobbing=0
camera_shake=0
screen_animations=0
EOF
}
