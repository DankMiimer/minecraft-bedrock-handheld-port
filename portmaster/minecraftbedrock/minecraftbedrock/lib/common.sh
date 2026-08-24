#!/bin/bash
# Shared, side-effect-light helpers for both Minecraft Bedrock editions.

# --- Canonical CFW identity ---------------------------------------------------
# One resolver so every per-CFW behaviour keys off the same answer. This
# replaces four ad-hoc detectors (two for muOS, two for Knulli) that had
# drifted apart, and gives ROCKNIX and the ArkOS family an identity they never
# had -- both were previously only inferred incidentally from `pidof sway` or
# from falling through to the generic profile.
#
#   MCPE_CFW             knulli|muos|rocknix|arkos|batocera|unknown
#   MCPE_CFW_CONFIDENCE  explicit  the system named itself (PortMaster
#                                  CFW_NAME, or /etc/os-release)
#                        inferred  filesystem layout markers only
#                        override  MCPE_CFW_OVERRIDE was set
#                        none      nothing matched
#
# The ArkOS family (ArkOS, dArkOS, DarkOS RE, ArkOS-for-clone) reports as
# `arkos`: they share the PortMaster layout, ESUDO=sudo, and the direct-KMSDRM
# display path, which is what this port actually branches on. Knulli is a
# Batocera derivative and is matched first so it is never reported as its
# upstream. Aurknix is deliberately absent from the name table: it is described
# inconsistently in this tree as both a ROCKNIX and an ArkOS derivative, so it
# is left to resolve on layout markers rather than on a guess.
#
# Names are matched before filesystem markers because a system that names
# itself is never wrong, while markers can be left behind on a shared SD card
# by a previous install.
mcpe_cfw_from_name() { # name -> prints canonical id, or fails
  local lower
  lower="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    "")         return 1 ;;
    *knulli*)   printf 'knulli\n' ;;
    *muos*)     printf 'muos\n' ;;
    *rocknix*)  printf 'rocknix\n' ;;
    # Both "darkos" and "dArkOSRE" contain "arkos".
    *arkos*)    printf 'arkos\n' ;;
    *batocera*) printf 'batocera\n' ;;
    *)          return 1 ;;
  esac
}

mcpe_osrelease_field() { # file field
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 | sed 's/^"//;s/"$//'
}

mcpe_resolve_cfw() {
  local probe="${MCPE_PROBE_ROOT:-}" id="" origin="" field value osr

  osr="$probe/etc/os-release"

  if [ -n "${MCPE_CFW_OVERRIDE:-}" ]; then
    id="$(mcpe_cfw_from_name "$MCPE_CFW_OVERRIDE")" || id=unknown
    origin=override
  fi
  if [ -z "$id" ] && id="$(mcpe_cfw_from_name "${CFW_NAME:-}")"; then
    origin=explicit
  fi
  if [ -z "$id" ] && [ -r "$osr" ]; then
    # Match against every field at once rather than field by field. A
    # derivative often keeps its upstream's NAME and only announces itself in
    # PRETTY_NAME -- Knulli reports NAME="Batocera" -- and stopping at the
    # first field that matched anything would then report the upstream.
    # mcpe_cfw_from_name already orders derivatives ahead of their upstreams,
    # so one match over the joined text gives the right precedence.
    value=""
    for field in OS_NAME NAME ID ID_LIKE PRETTY_NAME VERSION; do
      value="$value $(mcpe_osrelease_field "$osr" "$field")"
    done
    if id="$(mcpe_cfw_from_name "$value")"; then
      origin=explicit
    else
      id=""
    fi
  fi
  if [ -z "$id" ]; then
    origin=inferred
    if [ -d "$probe/opt/muos" ] || [ -d "$probe/mnt/mmc/MUOS" ] ||
       [ -d "$probe/mnt/sdcard/MUOS" ] ||
       [ -e "$probe/opt/muos/script/var/global/device.txt" ]; then
      id=muos
    elif [ -d "$probe/opt/system/Tools/PortMaster" ]; then
      # ArkOS-family tools layout; dArkOS RE reports exactly this path in the
      # field logs behind issue #1.
      id=arkos
    elif [ -d "$probe/storage/.config" ] && [ -d "$probe/storage/roms" ]; then
      # LibreELEC-derived read-only root, as used by ROCKNIX.
      id=rocknix
    elif [ -d "$probe/userdata/system" ]; then
      # Batocera-derived. Knulli is one of these, but this tree has no verified
      # marker separating it from upstream, so Knulli is only reported as such
      # when the system names itself -- which PortMaster does do on Knulli.
      id=batocera
    else
      id=unknown
      origin=none
    fi
  fi

  MCPE_CFW="$id"
  MCPE_CFW_CONFIDENCE="$origin"
  MCPE_CFW_CACHE_KEY="$(mcpe_cfw_cache_key)"
  export MCPE_CFW MCPE_CFW_CONFIDENCE MCPE_CFW_CACHE_KEY
}

mcpe_cfw_cache_key() {
  printf '%s|%s|%s\n' "${MCPE_CFW_OVERRIDE:-}" "${CFW_NAME:-}" "${MCPE_PROBE_ROOT:-}"
}

# CFW_NAME only becomes available after PortMaster's control files are sourced.
# A cached answer taken before that point would otherwise stick for the whole
# run and silently disable every per-CFW behaviour, so the cache is keyed on the
# inputs and re-resolves whenever they change.
mcpe_is_cfw() { # id [id...]
  local want
  if [ -z "${MCPE_CFW:-}" ] ||
     [ "${MCPE_CFW_CACHE_KEY:-}" != "$(mcpe_cfw_cache_key)" ]; then
    mcpe_resolve_cfw
  fi
  for want in "$@"; do
    [ "$MCPE_CFW" = "$want" ] && return 0
  done
  return 1
}

# --- Launch stage breadcrumb --------------------------------------------------
# A single token, overwritten in place, so a device that is hard-reset or
# powered off mid-launch still records where it stopped. The previous run's
# final stage is kept as stage.prev.txt and reported at the next boot: the
# RG35XX-H/Knulli hang (issue #2) produced no log at all, because the log is
# truncated on start and the console froze before anything useful was written.
#
# Tokens, in order: boot payload migrate probe menu version abi runtime
#                   client-exec window first-frame shutdown done
# `window` and `first-frame` are written by the startup watchdog and are not
# emitted yet; a run that stops at `client-exec` means the client was started
# and never came back.
# Preserve anything the parent already exported. run_bedrock.sh, weston_launch.sh
# and run_bedrock32.sh all source this file, so a plain assignment here silently
# disarmed the breadcrumb for every child: a live launch on the reference
# RG34XX-SP recorded `version` and then jumped straight to `done`, losing the
# `client-exec`, `window` and `first-frame` stages -- exactly the ones that
# matter for diagnosing a hang.
MCPE_STAGE_FILE="${MCPE_STAGE_FILE:-}"
MCPE_STAGE_PREV="${MCPE_STAGE_PREV:-}"

mcpe_stage() { # token
  [ -n "${MCPE_STAGE_FILE:-}" ] || return 0
  printf '%s\t%s\n' "$1" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
    >"$MCPE_STAGE_FILE" 2>/dev/null || true
}

mcpe_stage_begin() { # [logdir]
  local dir="${1:-$GAMEDIR/logs}"
  mkdir -p "$dir" 2>/dev/null || return 0
  MCPE_STAGE_FILE="$dir/stage.txt"
  MCPE_STAGE_PREV=""
  if [ -s "$MCPE_STAGE_FILE" ]; then
    MCPE_STAGE_PREV="$(cut -f1 <"$MCPE_STAGE_FILE" 2>/dev/null | head -1)"
    mv -f "$MCPE_STAGE_FILE" "$dir/stage.prev.txt" 2>/dev/null || true
  fi
  export MCPE_STAGE_FILE MCPE_STAGE_PREV
  mcpe_stage boot
}

# --- Boot report ---------------------------------------------------------------
# Everything a device report needs, in one block, accumulated as each value is
# resolved and printed once before the game starts. These facts were previously
# spread over a dozen echo lines in three scripts, in no fixed order, so no two
# reports looked alike. Child scripts inherit MCPE_REPORT_FILE and append to the
# same file.
mcpe_report_begin() { # [file]
  MCPE_REPORT_FILE="${1:-$GAMEDIR/logs/boot-report.txt}"
  mkdir -p "$(dirname "$MCPE_REPORT_FILE")" 2>/dev/null || { MCPE_REPORT_FILE=""; return 0; }
  : >"$MCPE_REPORT_FILE" 2>/dev/null || MCPE_REPORT_FILE=""
  export MCPE_REPORT_FILE
}

mcpe_report_set() { # key value...
  local key="$1"
  shift
  [ -n "${MCPE_REPORT_FILE:-}" ] || return 0
  printf '%s=%s\n' "$key" "$*" >>"$MCPE_REPORT_FILE" 2>/dev/null || true
}

mcpe_report_print() {
  [ -n "${MCPE_REPORT_FILE:-}" ] && [ -s "$MCPE_REPORT_FILE" ] || return 0
  echo "--- boot report ---"
  sed 's/^/  /' "$MCPE_REPORT_FILE" 2>/dev/null || true
  echo "-------------------"
}

mcpe_json_string() { # file key
  sed -n 's/^[[:space:]]*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# The marketing version ("1.16.221.01") of an installed version directory,
# whose own name also carries the version code and ABI
# ("1.16.221.01-971622101-arm64"). version.json is authoritative; the directory
# name is the fallback for payloads extracted before this tree wrote metadata.
# Prints nothing when neither yields a dotted-numeric version, which callers
# read as "unknown" rather than guessing.
mcpe_version_name() { # version_dir_name [versions_root]
  local dir="${1:-}" root="${2:-$GAMEDIR/versions}" name=""
  [ -n "$dir" ] || return 1
  [ -f "$root/$dir/version.json" ] &&
    name="$(mcpe_json_string "$root/$dir/version.json" version_name)"
  if [ -z "$name" ]; then
    case "$dir" in
      *-*-arm64|*-*-armhf) name="${dir%-*-*}" ;;
      *) name="$dir" ;;
    esac
  fi
  case "$name" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  printf '%s\n' "$name"
}

mcpe_load_edition() {
  local manifest="${1:-$GAMEDIR/edition.json}"
  [ -f "$manifest" ] || { echo "missing edition manifest: $manifest" >&2; return 1; }
  MCPE_EDITION_ID="$(mcpe_json_string "$manifest" id)"
  MCPE_EDITION_NAME="$(mcpe_json_string "$manifest" name)"
  MCPE_PAYLOAD_NAME="$(mcpe_json_string "$manifest" payload)"
  MCPE_DEFAULT_CHANNEL="$(mcpe_json_string "$manifest" channel)"
  MCPE_SHARED_DIRNAME="$(mcpe_json_string "$manifest" shared_data)"
  [ -n "$MCPE_EDITION_ID" ] && [ -n "$MCPE_PAYLOAD_NAME" ] || return 1
  export MCPE_EDITION_ID MCPE_EDITION_NAME MCPE_PAYLOAD_NAME
  export MCPE_DEFAULT_CHANNEL MCPE_SHARED_DIRNAME
}

mcpe_is_empty_dir() {
  [ -d "$1" ] || return 1
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

mcpe_safe_component() {
  case "$1" in ""|.|..|.*|*/*|*\\*|*$'\n'*|*$'\r'*) return 1 ;; esac
  return 0
}

mcpe_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else
    return 127
  fi
}

mcpe_fetch() { # url destination
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 15 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    return 127
  fi
}

mcpe_archive_is_safe() {
  unzip -Z1 "$1" 2>/dev/null | awk '
    BEGIN { bad=0 }
    /^\// || /^[A-Za-z]:/ { bad=1 }
    /(^|\/)\.\.($|\/)/ { bad=1 }
    /\\/ { bad=1 }
    END { exit bad }
  '
}

mcpe_select_utf8_locale() {
  # Minimal CFW images often export an en_US locale they did not actually
  # install. C/C++ filesystem conversion then fails on non-ASCII world names.
  # Keep a working UTF-8 locale when provided; otherwise select the first one
  # the host can instantiate without requiring locale generation or writes.
  local candidate charmap
  for candidate in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}" \
                   C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    [ -n "$candidate" ] || continue
    if command -v locale >/dev/null 2>&1; then
      charmap="$(LC_ALL="$candidate" locale charmap 2>/dev/null || true)"
      case "$(printf '%s' "$charmap" | tr '[:lower:]' '[:upper:]')" in
        UTF-8|UTF8) ;;
        *) continue ;;
      esac
    else
      case "$candidate" in C.UTF-8|C.utf8) ;; *) continue ;; esac
    fi
    export LANG="$candidate" LC_CTYPE="$candidate" LC_ALL="$candidate"
    MCPE_LOCALE_RESOLVED="$candidate"
    export MCPE_LOCALE_RESOLVED
    return 0
  done
  # Do not invent an unsupported locale. Byte-oriented C is safer than a
  # broken locale name and is recorded in diagnostics for the device report.
  export LANG=C LC_CTYPE=C LC_ALL=C MCPE_LOCALE_RESOLVED=C
}

# --- UI zoom target -----------------------------------------------------------
# Newer Bedrock builds (measured on 1.21.51.01) derive their entire UI scale
# from the real render surface: the reported screen size, the reported DPI and
# gfx_guiscale_offset are all ignored. Rendering below the panel and letting
# the display scaler enlarge the result is the only lever that still moves
# their UI, so the "UI zoom" setting picks a smaller surface here.
#
# The exact ratio is kept rather than nudged onto a convenient size: this stack
# only holds surfaces whose sides are multiples of 16, and stretching a panel
# onto a size it does not divide into would distort the picture rather than
# rescue it. The caller checks alignment and verifies the mode really took.
mcpe_zoom_target() { # panel_w panel_h zoom -> "width height"
  local w="$1" h="$2" zoom="${3:-1}"
  case "$w$h" in *[!0-9]*|"") printf '%s %s\n' "$w" "$h"; return 0 ;; esac
  case "$zoom" in
    1.25) printf '%s %s\n' "$((w * 4 / 5))" "$((h * 4 / 5))" ;;
    1.5) printf '%s %s\n' "$((w * 2 / 3))" "$((h * 2 / 3))" ;;
    *) printf '%s %s\n' "$w" "$h" ;;
  esac
}

# Is this surface size safe for the Mali/disp2 path? fbset alone proves
# nothing: every size tested here survives the call while the device is idle,
# yet 600x400 is back at the panel size once the game has a surface, and
# 360x240 leaves the framebuffer geometry and the rendered content disagreeing.
# Both are the sizes that are not multiples of 16; 480x320 is, and holds.
mcpe_fb_mode_aligned() { # width height
  local w="$1" h="$2"
  case "$w$h" in *[!0-9]*|"") return 1 ;; esac
  [ "$((w % 16))" = 0 ] && [ "$((h % 16))" = 0 ]
}
