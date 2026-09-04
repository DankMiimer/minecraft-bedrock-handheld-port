#!/bin/bash
# Physically validated defaults for the two launcher classes.  Keep the
# 512-MB armhf/R36S profile separate from the arm64 handheld profile: they
# require very different graphics budgets.

# --- Device memory -------------------------------------------------------------
# Every supported handheld is one of four fittings, and the port has to know
# which one it is on before it can decide how much world to keep resident.
#
# MemTotal never equals the fitting: the kernel counts what is left after the
# firmware's carveouts, so the boundaries below sit between fittings rather
# than on them. Measured on reference hardware:
#
#   R36S (RK3326, 512 MB)      ~ 500 MB   -> 512m
#   RG35XX-family H700, 1 GB   ~1000 MB   -> 1g
#   RG34XX-SP (H700, 2 GB)      1980 MB   -> 2g   (2027140 kB, measured)
#
# 3 GB has no reference device in this tree yet; its row is derived from the
# 2 GB one rather than measured, and is deliberately the smallest step.
# mcpe_meminfo_kb / mcpe_proc_ppid / mcpe_fb_geometry live in common.sh. Load it
# here too so this file stays usable on its own, the way platform.sh does.
if ! type mcpe_meminfo_kb >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

mcpe_memory_mb() { # [mem_kb] -> MiB, 0 when the host would not say
  local kb="${1:-${MCPE_HOST_MEMORY_KB:-}}"
  [ -n "$kb" ] || kb="$(mcpe_meminfo_kb 2>/dev/null)"
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  printf '%s\n' "$((kb / 1024))"
}

mcpe_memory_tier() { # [mem_mb] -> 512m|1g|2g|3g|unknown
  local mb="${1:-$(mcpe_memory_mb)}"
  case "$mb" in ''|*[!0-9]*) mb=0 ;; esac
  if   [ "$mb" -le 0 ];    then printf 'unknown\n'
  elif [ "$mb" -lt 768 ];  then printf '512m\n'
  elif [ "$mb" -lt 1536 ]; then printf '1g\n'
  elif [ "$mb" -lt 2560 ]; then printf '2g\n'
  else                          printf '3g\n'
  fi
}

# What is actually the game's to spend. The remainder is firmware, Weston, the
# launcher/companion processes and page-cache headroom. The original 2 GB
# measurement included a resident ES-DE; the frontend now closes during play,
# so this one-fifth reserve is intentionally conservative until a post-handoff
# memory trace justifies raising the game's advertised limit. The floor keeps
# a 512 MB device from reserving so little that the firmware has nowhere to
# live, and the ceiling stops a large device donating headroom nothing uses.
mcpe_memory_budget_mb() { # [mem_mb] -> MiB, 0 when unknown
  local mb="${1:-$(mcpe_memory_mb)}" reserve
  case "$mb" in ''|*[!0-9]*) mb=0 ;; esac
  [ "$mb" -gt 0 ] || { printf '0\n'; return 0; }
  reserve=$((mb / 5))
  [ "$reserve" -lt 160 ] && reserve=160
  [ "$reserve" -gt 512 ] && reserve=512
  # On a device too small for the flat floor, the floor would take most of the
  # machine -- at 200 MB it leaves the game 40. Never reserve more than half.
  [ "$reserve" -gt $((mb / 2)) ] && reserve=$((mb / 2))
  printf '%s\n' "$((mb - reserve))"
}

# Resolve the tier and publish it. Two consumers:
#
#   * this file's own presets, below, which size the resident world;
#   * the client, which answers Android's getMemoryLimit/getFreeMemory from
#     MCPE_GAME_MEMORY_BUDGET_MB rather than from physical RAM.
#
# Must run *before* mcpe_apply_arm64_defaults so the tier's values are what
# that function's ${VAR:-default} expansions see. The precedence that gives is
# the one the port wants: caller environment, then measured tier, then the
# ABI-wide default.
mcpe_apply_memory_profile() { # abi
  local abi="${1:-}" mb tier budget
  mb="$(mcpe_memory_mb)"
  tier="$(mcpe_memory_tier "$mb")"
  budget="$(mcpe_memory_budget_mb "$mb")"
  export MCPE_HOST_MEMORY_MB="$mb"
  export MCPE_MEMORY_TIER="$tier"
  [ "$budget" -gt 0 ] &&
    export MCPE_GAME_MEMORY_BUDGET_MB="${MCPE_GAME_MEMORY_BUDGET_MB:-$budget}"

  # An unreadable /proc/meminfo must not quietly reclassify a working device.
  # Leaving the presets alone reproduces the port's behaviour before tiers.
  [ "$tier" = unknown ] && return 0
  # The armhf client has its own physically validated R36S profile, which is
  # already below everything the 512m row would ask for.
  [ "$abi" = arm64 ] || return 0

  # gfx_viewdistance is in blocks. 80 is both the 2 GB reference value and the
  # engine's own floor -- a request below it is clamped straight back up, which
  # this tree already measured on 1.16 when the R36S profile asked for 32 -- so
  # there is no downward lever here and only the 3 GB row moves.
  #
  # The frame cap is deliberately *not* a tier knob: the panel cadence that
  # decides it is a property of the display, not of how much RAM is fitted.
  # It is keyed off the game version instead -- see mcpe_default_max_fps.
  #
  # gfx_max_dequeued_textures_per_frame is the streaming budget: how much
  # texture upload the renderer may take on in one frame. It is where a small
  # device actually differs, and the R36S profile already pins it to 2 for
  # exactly this reason.
  case "$tier" in
    512m)
      export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-80}"
      export MCPE_TEXTURE_DEQUEUE="${MCPE_TEXTURE_DEQUEUE:-2}"
      ;;
    1g)
      export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-80}"
      export MCPE_TEXTURE_DEQUEUE="${MCPE_TEXTURE_DEQUEUE:-8}"
      ;;
    2g)
      export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-80}"
      export MCPE_TEXTURE_DEQUEUE="${MCPE_TEXTURE_DEQUEUE:-16}"
      ;;
    3g)
      export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-112}"
      export MCPE_TEXTURE_DEQUEUE="${MCPE_TEXTURE_DEQUEUE:-16}"
      ;;
  esac
}

# --- Frame cap -----------------------------------------------------------------
# Even with vsync off the panel only swaps on a refresh boundary, so what
# reaches the eye is the whole number of refresh intervals each frame is held
# for. A cap whose frame time lands between two multiples turns every frame
# into a coin flip between them, which is what reads as judder.
#
# Measured on the RG34XX-SP's 59.156 Hz panel (superflat, stationary,
# 1.16.221.01, vsync off, one 60-90s window per cap):
#
#   cap 60 -> 57.5 fps  1.03 intervals  1x94% 2x6%    hold stdev 0.24
#   cap 50 -> 47.0 fps  1.26 intervals  1x74% 2x26%   hold stdev 0.44
#   cap 40 -> 37.9 fps  1.56 intervals  1x44% 2x56%   hold stdev 0.50
#   cap 30 -> 29.0 fps  2.04 intervals  2x92%         hold stdev 0.29
#
# Repeated in a generated world at the shipped 80-block render distance, which
# is what players actually run, and the result is the same within noise:
#
#   cap 50 -> 46.2 fps  1.28 intervals  1x73% 2x27%   hold stdev 0.44
#   cap 30 -> 28.9 fps  2.04 intervals  2x91%         hold stdev 0.30
#
# So the cap still binds under real terrain load at 80 blocks, and the choice
# between these two is a real one. It stops mattering once the scene outruns
# the cap: at 192 blocks the same world is GPU-bound at 32 fps and lands on
# 1.85 intervals whatever the cap says (2x84%, hold stdev 0.37). A cap can
# only place frames while the device can beat it.
#
# 40 sat almost exactly halfway between two multiples -- the worst value
# available on this panel -- so it is no longer the default anywhere. Every cap
# came in 4-6% under its target; that is limiter overhead, not lost frames
# (p99 stayed inside the cap's own interval in every window).
#
# 1.16.221.01 and older render cheaply enough to hold a high cap, and there the
# responsiveness is worth pacing less even than 30's. 50 buys 18 fps over 30
# for a 74/26 hold split instead of 92% steady, and its frame-to-frame jitter
# is actually the second lowest of the four (2.48ms against 30's 2.30ms and
# 40's 3.31ms) -- the renderer is steady, it is the scanout cadence that is
# not. There is no clean divisor between 29.6 and 59.2 on this panel, so that
# trade is unavoidable at this frame rate. Newer builds are heavier, so they
# take the cap that stays binding -- and therefore evenly paced -- under load.
#
# armhf/R36S is not part of this split: its 10 fps cap is a throughput limit on
# a much weaker device, not a cadence choice.
MCPE_MAX_FPS_LEGACY="${MCPE_MAX_FPS_LEGACY:-50}"
MCPE_MAX_FPS_MODERN="${MCPE_MAX_FPS_MODERN:-30}"
MCPE_MAX_FPS_LEGACY_UNTIL="${MCPE_MAX_FPS_LEGACY_UNTIL:-1.16.221.01}"

# Numeric dotted-version comparison, true when $1 <= $2. Written out rather
# than shelled out to `sort -V`, which the busybox userlands this port also
# runs on do not reliably provide. Absent components count as zero, so
# "1.16" <= "1.16.221.01" and "1.16.221" <= "1.16.221.01".
mcpe_version_le() { # left right
  local left="$1" right="$2" l r
  while [ -n "$left" ] || [ -n "$right" ]; do
    l="${left%%.*}"; r="${right%%.*}"
    case "$l" in ''|*[!0-9]*) l=0 ;; esac
    case "$r" in ''|*[!0-9]*) r=0 ;; esac
    [ "$l" -lt "$r" ] && return 0
    [ "$l" -gt "$r" ] && return 1
    case "$left"  in *.*) left="${left#*.}"   ;; *) left=""  ;; esac
    case "$right" in *.*) right="${right#*.}" ;; *) right="" ;; esac
  done
  return 0
}

# A missing or unparseable version takes the modern cap: it is the conservative
# one, and a version this cannot read is not one that was measured here.
mcpe_default_max_fps() { # [version_name]
  local version="${1:-}"
  case "$version" in
    ''|*[!0-9.]*) printf '%s\n' "$MCPE_MAX_FPS_MODERN"; return 0 ;;
  esac
  if mcpe_version_le "$version" "$MCPE_MAX_FPS_LEGACY_UNTIL"; then
    printf '%s\n' "$MCPE_MAX_FPS_LEGACY"
  else
    printf '%s\n' "$MCPE_MAX_FPS_MODERN"
  fi
}

mcpe_apply_arm64_defaults() { # abi [version_name]
  local abi="${1:-}" version="${2:-}"
  [ "$abi" = arm64 ] || return 0

  export MCPE_ARM64_HANDHELD_PRESET=1
  export MCPE_MAX_FPS="${MCPE_MAX_FPS:-$(mcpe_default_max_fps "$version")}"
  export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-80}"
  export MCPE_VSYNC="${MCPE_VSYNC:-0}"
  # Stock density. The client's scale setting reaches the game only as an
  # Android DPI, and it never enlarged the UI this port cares about: measured
  # on 1.21.51.01, the game does not call getPixelsPerMillimeter at all and the
  # HUD, inventory and menus are pixel-identical at 1, 2 and 3. The one thing
  # the DPI still reaches is Ore UI -- cohtml reads it -- so a value above 1
  # rendered the Create New World and death screens at double scale until they
  # overflowed the panel, on 1.16 and 1.21 alike. Raise it only to make those
  # Ore UI screens bigger; use the UI zoom setting to enlarge everything else.
  export MCPE_UI_DENSITY_SCALE="${MCPE_UI_DENSITY_SCALE:-1}"
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
