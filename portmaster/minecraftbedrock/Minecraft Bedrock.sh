#!/bin/bash
# Minecraft Bedrock Edition (mcpelauncher, EGLUT/Weston) — manual install.
# Target: ARM handhelds on Knulli/muOS H700, ROCKNIX/Aurknix Mali devices,
# and RK3326/R36S-class PortMaster setups via the 32-bit SDL path.
# Reference gates: RG34XX-SP/H700 and R36S/armhf. RGDS uses its own edition.
#
# Place this script and the minecraftbedrock/ folder together in your ports
# directory. muOS split installs are also supported:
#   /roms/Ports/Minecraft Bedrock.sh + /ports/minecraftbedrock/

mcpe_now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  case "$value" in ''|*[!0-9]*) value=$(( $(date +%s 2>/dev/null || echo 0) * 1000 )) ;; esac
  printf '%s\n' "$value"
}

MCPE_BOOT_START_MS="$(mcpe_now_ms)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORTDIR="${MCPE_ENTRY_DIR_OVERRIDE:-$SCRIPT_DIR}"
PAYLOAD_NAME="${MCPE_PAYLOAD_NAME_OVERRIDE:-minecraftbedrock}"

HOST_MACHINE="$(uname -m 2>/dev/null || echo unknown)"
case "$HOST_MACHINE" in
  aarch64|arm64|armv7l|armv8l|arm*) ;;
  *)
    echo "This port requires an ARM Linux handheld."
    exit 1
    ;;
esac

# Native 32-bit firmwares need PortMaster's armhf mod path before CFW mods are
# sourced. On 64-bit firmwares the launcher can still choose the armhf binary
# later when it is the better fit (R36S-style low-memory path).
case "$HOST_MACHINE" in
  aarch64|arm64) ;;
  *) export PORT_32BIT=Y ;;
esac

# A handheld launcher control.txt is optional for this port (the 64-bit
# EGLUT client maps pads itself), but source it when present for ESUDO,
# CFW_NAME, directory, pm_platform_helper — and get_controls, whose SDL
# mapping line the 32-bit SDL client and the LOVE menu use.
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
PM_DIR="$(printf '\120\157\162\164\115\141\163\164\145\162')"
for cf in "/opt/system/Tools/$PM_DIR" "/opt/tools/$PM_DIR" \
          "$XDG_DATA_HOME/$PM_DIR" "/userdata/system/.local/share/$PM_DIR" \
          "/storage/roms/ports/$PM_DIR" "/roms/ports/$PM_DIR" \
          "/roms/tools/$PM_DIR" "/roms2/tools/$PM_DIR" \
          "/mnt/mmc/MUOS/$PM_DIR" "/mnt/sdcard/MUOS/$PM_DIR" \
          "/mnt/mmc/ROMS/Ports/$PM_DIR" "/mnt/sdcard/ROMS/Ports/$PM_DIR"; do
  if [ -f "$cf/control.txt" ]; then
    # Some CFW control.txt files rewrite controlfolder to the ROMs directory,
    # even though the runtime that we just found lives in cf.  Preserve the
    # authoritative root so later runtime discovery cannot silently drift.
    PM_CONTROL_ROOT="$cf"
    controlfolder="$PM_CONTROL_ROOT"
    source "$cf/control.txt" 2>/dev/null || true
    [ -f "$cf/device_info.txt" ] && source "$cf/device_info.txt" 2>/dev/null || true
    [ -n "${CFW_NAME:-}" ] && [ -f "$cf/mod_${CFW_NAME}.txt" ] &&
      source "$cf/mod_${CFW_NAME}.txt" 2>/dev/null || true
    controlfolder="$PM_CONTROL_ROOT"
    break
  fi
done
export controlfolder="${controlfolder:-}"
export PM_CONTROL_ROOT="${PM_CONTROL_ROOT:-$controlfolder}"
export ESUDO="${ESUDO:-}"
export CFW_NAME="${CFW_NAME:-}"
# These are shell variables in several PortMaster control.txt versions.  Export
# them explicitly so the architecture-specific launcher can start/stop the
# same controller-to-keyboard helper used by the original R36S port.
export GPTOKEYB="${GPTOKEYB:-}"
export GPTOKEYB2="${GPTOKEYB2:-}"
if type get_controls >/dev/null 2>&1; then
  get_controls 2>/dev/null || true
fi
export sdl_controllerconfig="${sdl_controllerconfig:-}"

# The sourced PortMaster files can clobber SCRIPT_DIR (seen on Knulli:
# pick_game_dir then resolved "/minecraftbedrock"). Restore it from the
# copy taken before sourcing.
SCRIPT_DIR="$PORTDIR"

# CFW identity is resolved once by mcpe_resolve_cfw, immediately after
# lib/common.sh loads below. It needs CFW_NAME from the PortMaster control
# files sourced above, so it cannot run any earlier than this point.

try_game_dir() {
  [ -f "$1/run_bedrock.sh" ] && [ -f "$1/setup_apk.sh" ] &&
    { echo "$1"; return 0; }
  return 1
}

pick_game_dir() {
  local base parent pbase root
  try_game_dir "$SCRIPT_DIR/$PAYLOAD_NAME" && return
  [ -n "${directory:-}" ] && try_game_dir "/$directory/ports/$PAYLOAD_NAME" && return
  try_game_dir "/mnt/mmc/ports/$PAYLOAD_NAME" && return
  try_game_dir "/mnt/sdcard/ports/$PAYLOAD_NAME" && return
  try_game_dir "/storage/ports/$PAYLOAD_NAME" && return
  try_game_dir "/roms/ports/$PAYLOAD_NAME" && return
  try_game_dir "/userdata/roms/ports/$PAYLOAD_NAME" && return

  base="$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]')"
  parent="$(dirname "$SCRIPT_DIR")"
  pbase="$(basename "$parent" | tr '[:upper:]' '[:lower:]')"
  if [ "$base" = "ports" ] && [ "$pbase" = "roms" ]; then
    root="$(dirname "$parent")"
    try_game_dir "$root/ports/$PAYLOAD_NAME" && return
    try_game_dir "$root/Ports/$PAYLOAD_NAME" && return
  fi

  echo "$SCRIPT_DIR/$PAYLOAD_NAME"
}

GAMEDIR="${MCPE_GAMEDIR_OVERRIDE:-$(pick_game_dir)}"
export GAMEDIR
CONFDIR="$GAMEDIR/config"

mkdir -p "$CONFDIR" "$GAMEDIR/logs" "$GAMEDIR/runtime"
STARTUP_TIMING="$GAMEDIR/logs/startup-timing.log"
: >"$STARTUP_TIMING" 2>/dev/null || true
mcpe_startup_mark() {
  local now
  now="$(mcpe_now_ms)"
  printf '%s ms\t%s\n' "$((now - MCPE_BOOT_START_MS))" "$1" >>"$STARTUP_TIMING" 2>/dev/null || true
}
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh" || { echo "Missing common runtime helpers."; exit 1; }
# The breadcrumb is opened before anything that can hang, and the launcher log
# is not truncated until after the capability probe, so these two files are the
# only record a device leaves when it locks up during startup.
mcpe_stage_begin "$GAMEDIR/logs"
mcpe_report_begin "$GAMEDIR/logs/boot-report.txt"
mcpe_resolve_cfw
mcpe_stage payload
mcpe_startup_mark "payload resolved"
mcpe_load_edition "$GAMEDIR/edition.json" || { echo "Invalid edition manifest."; exit 1; }
mcpe_select_utf8_locale
# shellcheck disable=SC1091
source "$GAMEDIR/lib/migrate_data.sh" || exit 1
mcpe_stage migrate
mcpe_migrate_shared_data || { echo "Shared-data migration failed without overwriting user data."; exit 1; }
mcpe_startup_mark "shared data ready"
python3 "$GAMEDIR/migrate_version_metadata.py" "$GAMEDIR" ||
  echo "Legacy version metadata backfill failed; affected versions remain best effort."
mcpe_startup_mark "version metadata ready"
# shellcheck disable=SC1091
source "$GAMEDIR/lib/platform.sh" || exit 1
mcpe_apply_platform_profile "$CONFDIR/resolved_host.env" || { echo "Host capability probe failed."; exit 1; }
mcpe_startup_mark "device profile ready"

> "$GAMEDIR/logs/launcher.log" && ln -sfn "logs/launcher.log" "$GAMEDIR/log.txt" 2>/dev/null || true
exec > >(tee -a "$GAMEDIR/logs/launcher.log") 2>&1
cd "$GAMEDIR"
echo "Port dir: $PORTDIR"
echo "Game dir: $GAMEDIR"
echo "Edition: $MCPE_EDITION_ID"
echo "Shared data: $MCPE_SHARED_ROOT"
echo "CFW: ${CFW_NAME:-unknown} profile=${MCPE_HOST_PROFILE:-generic} backend=${MCPE_GRAPHICS_BACKEND_RESOLVED:-unknown}"
echo "Locale: ${MCPE_LOCALE_RESOLVED:-unknown}"

# The Weston runtime (weston_pkg_0.2) is only needed by the 64-bit EGLUT path,
# so it is resolved lazily in run_bedrock.sh's arm64 branch — a 32-bit-only
# install on a kmsdrm device (e.g. R36S) must not fail here for a missing
# Weston it will never use.
export PM_DIR

# On-screen messaging: fbdev CFWs (Knulli) show tty1 while a port runs;
# under a DRM compositor (ROCKNIX/sway) there is no portable text surface,
# so the message goes to the log and ES returns quickly.
# SHOW_MSG_SLEEP overrides the read pause for quick progress notes.
show_msg() {
  echo "$*"
  if ! pidof sway >/dev/null 2>&1 && [ -w /dev/tty1 ]; then
    {
      clear
      echo
      echo "  ================ MINECRAFT BEDROCK ================"
      echo
      printf '  %s\n' "$@"
      echo
      echo "  ==================================================="
    } > /dev/tty1 2>/dev/null
    sleep "${SHOW_MSG_SLEEP:-6}"
  fi
}

# The standard build intentionally has no RGDS dual-screen payload. Its only
# RGDS-specific behavior is this redirect into the separately versioned build.
if [ "$MCPE_EDITION_ID" = minecraftbedrock.standard ] && [ "${MCPE_IS_RGDS:-0}" = 1 ]; then
  export MCPE_REDIRECT_RGDS=1
fi

# version_env.py imports the APK verifier and costs about half a second on an
# H700 microSD even when it only reads JSON. Resolve once before the menu and
# refresh only after an action actually changes installed versions.
MCPE_LATEST_INSTALLED=""
refresh_installed_version() {
  MCPE_LATEST_INSTALLED="$(
    python3 "$GAMEDIR/version_env.py" "$GAMEDIR" --select-latest 2>/dev/null
  )" || MCPE_LATEST_INSTALLED=""
}
has_installed_version() {
  [ -n "$MCPE_LATEST_INSTALLED" ] &&
    [ -d "$GAMEDIR/versions/$MCPE_LATEST_INSTALLED" ]
}
refresh_installed_version
mcpe_startup_mark "installed version selected"

import_legacy_r36s_versions() {
  has_installed_version && return 0
  local legacy v imported
  imported=0
  for legacy in \
    "$PORTDIR/mcpe_launcher" \
    "$(dirname "$GAMEDIR")/mcpe_launcher" \
    "/roms/ports/mcpe_launcher" \
    "/storage/roms/ports/mcpe_launcher" \
    "/roms2/ports/mcpe_launcher" \
    "/storage/roms2/ports/mcpe_launcher"
  do
    [ -d "$legacy/versions" ] || continue
    show_msg "Found legacy R36S mcpe_launcher versions." \
             "Importing them into minecraftbedrock..."
    for v in "$legacy/versions"/*; do
      [ -d "$v" ] || continue
      [ -d "$GAMEDIR/versions/$(basename "$v")" ] && continue
      cp -r "$v" "$GAMEDIR/versions/"
      imported=1
    done
    if [ "$imported" = 1 ]; then
      refresh_installed_version
      show_msg "Legacy versions imported."
    fi
    return 0
  done
}

import_legacy_r36s_versions

# --- Launcher menu availability ------------------------------------------------
# The LOVE menu (version picker, APK installer, settings) runs wherever
# PortMaster's love runtime is installed: nested under sway (ROCKNIX), or
# straight on the CFW's SDL video stack (Knulli/muOS fbdev-mali). If the
# runtime is missing or the menu crashes, everything falls back to the old
# auto behavior. Disable with MCPE_MENU=0; custom shortcuts that pin
# MCVER_OVERRIDE skip it too.
find_love_txt() {
  local lt
  for lt in "$PM_CONTROL_ROOT/runtimes/love_11.5/love.txt" \
            "$controlfolder/runtimes/love_11.5/love.txt" \
            "$controlfolder/libs/love_11.5/love.txt" \
            "$controlfolder/runtimes/love/love.txt" \
            "/userdata/system/.local/share/$PM_DIR/runtimes/love_11.5/love.txt"; do
    [ -f "$lt" ] && { echo "$lt"; return 0; }
  done
  return 1
}
MENU_LOVE_TXT=""
MENU_WANTED=0
if [ "${MCPE_MENU:-auto}" != 0 ] && [ -z "${MCVER_OVERRIDE:-}" ] &&
   [ -f "$GAMEDIR/menu/main.lua" ]; then
  MENU_WANTED=1
  MENU_LOVE_TXT="$(find_love_txt)" || MENU_LOVE_TXT=""
fi
if [ "$MENU_WANTED" = 1 ] && [ -z "$MENU_LOVE_TXT" ] &&
   [ "${MCPE_MENU:-auto}" = 1 ]; then
  show_msg "Minecraft launcher menu unavailable." \
           "PortMaster's LOVE 11.5 runtime was not found." \
           "Update PortMaster, or set MCPE_MENU=0 to use legacy autoplay."
  exit 2
fi

# --- APK extraction --------------------------------------------------------------
# With the menu available, installs are user-driven from the Install screen, so
# a forgotten APK in apk/ no longer breaks every launch. Menu-less devices keep
# the old extract-on-launch behavior; a failure there is only fatal when
# nothing is installed yet.
# Extraction takes minutes with nothing on screen, which reads as a freeze.
# apkmeta.py publishes "<percent> <message>" to the progress file; redraw it
# until the installer exits.
draw_install_progress() { # pid progress_file
  local pid="$1" file="$2" line pct msg bar width filled i
  local last_pct=0 last_msg="preparing"
  if [ -n "${LOVE_RUN:-}" ] && [ -d "$GAMEDIR/downloader/progress-ui" ] &&
     ! pidof sway >/dev/null 2>&1; then
    SDL_AUDIODRIVER=dummy MCPE_PROGRESS_FILE="$file" MCPE_PROGRESS_KIND=install \
      $LOVE_RUN "$GAMEDIR/downloader/progress-ui" \
      >>"$GAMEDIR/logs/progress-ui.log" 2>&1 &
    local progress_ui_pid=$!
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    kill "$progress_ui_pid" 2>/dev/null || true
    wait "$progress_ui_pid" 2>/dev/null || true
    return 0
  fi
  pidof sway >/dev/null 2>&1 && return 0
  [ -w /dev/tty1 ] || return 0
  width=34
  while kill -0 "$pid" 2>/dev/null; do
    line="$(head -n 1 "$file" 2>/dev/null)"
    pct="${line%% *}"
    msg="${line#* }"
    # An unreadable sample keeps the previous reading rather than snapping the
    # bar back to zero.
    case "$pct" in ''|*[!0-9]*) pct="$last_pct"; msg="$last_msg" ;; esac
    [ -n "$msg" ] && [ "$msg" != "$line" ] || msg="$last_msg"
    last_pct="$pct"
    last_msg="$msg"
    filled=$(( pct * width / 100 ))
    bar=""
    i=0
    while [ "$i" -lt "$width" ]; do
      if [ "$i" -lt "$filled" ]; then bar="$bar#"; else bar="$bar."; fi
      i=$(( i + 1 ))
    done
    {
      clear
      echo
      echo "  ================ MINECRAFT BEDROCK ================"
      echo
      echo "  Installing game files - do not turn off"
      echo
      printf '  [%s] %3d%%\n' "$bar" "$pct"
      echo
      printf '  %s\n' "$msg"
      echo
      echo "  ==================================================="
    } > /dev/tty1 2>/dev/null
    sleep 1
  done
}

draw_downloader_progress_love() { # downloader_pid progress_file ack_file
  local downloader_pid="$1" file="$2" ack="$3"
  local ui_pid="" line mode failures=0
  [ -n "${LOVE_RUN:-}" ] || return 1
  [ -d "$GAMEDIR/downloader/progress-ui" ] || return 1
  pidof sway >/dev/null 2>&1 && return 1
  rm -f "$ack"
  while kill -0 "$downloader_pid" 2>/dev/null; do
    if [ -n "$ui_pid" ] && kill -0 "$ui_pid" 2>/dev/null; then
      sleep 0.2
      continue
    fi
    if [ -n "$ui_pid" ]; then
      wait "$ui_pid" 2>/dev/null || true
      ui_pid=""
    fi
    line="$(head -n 1 "$file" 2>/dev/null)"
    mode="$(printf '%s' "$line" | cut -d'|' -f2)"
    if [ "$mode" = interactive ]; then
      : >"$ack"
      while kill -0 "$downloader_pid" 2>/dev/null; do
        line="$(head -n 1 "$file" 2>/dev/null)"
        mode="$(printf '%s' "$line" | cut -d'|' -f2)"
        [ "$mode" = interactive ] || break
        sleep 0.2
      done
      failures=0
      continue
    fi
    if [ "$failures" -ge 3 ]; then
      # Keep servicing the interactive handshake even if LOVE cannot draw.
      sleep 0.5
      continue
    fi
    SDL_AUDIODRIVER=dummy MCPE_PROGRESS_FILE="$file" MCPE_PROGRESS_KIND=download \
      MCPE_PROGRESS_EXIT_INTERACTIVE=1 \
      $LOVE_RUN "$GAMEDIR/downloader/progress-ui" \
      >>"$GAMEDIR/logs/progress-ui.log" 2>&1 &
    ui_pid=$!
    failures=$((failures + 1))
    sleep 0.2
  done
  if [ -n "$ui_pid" ]; then
    kill "$ui_pid" 2>/dev/null || true
    wait "$ui_pid" 2>/dev/null || true
  fi
  rm -f "$ack"
  return 0
}

# The optional downloader has a long first-use preparation phase before its
# Weston/Qt Google window exists. Knulli otherwise leaves LOVE's confirmation
# frame on screen, which looks frozen. Show real milestones on tty1, but stop
# writing while the interactive Google window owns the framebuffer.
draw_downloader_progress() { # pid progress_file [interactive_ack]
  local pid="$1" file="$2" ack="${3:-}"
  local line pct mode heading detail bar width filled i
  local last_pct=1 last_mode=active last_heading="Starting Google Play downloader"
  local last_detail="Checking optional sign-in components."
  if [ -n "$ack" ] && draw_downloader_progress_love "$pid" "$file" "$ack"; then
    return 0
  fi
  pidof sway >/dev/null 2>&1 && return 0
  [ -w /dev/tty1 ] || return 0
  width=34
  while kill -0 "$pid" 2>/dev/null; do
    line="$(head -n 1 "$file" 2>/dev/null)"
    IFS='|' read -r pct mode heading detail <<<"$line"
    case "$pct" in ''|*[!0-9]*)
      pct="$last_pct"; mode="$last_mode"; heading="$last_heading"; detail="$last_detail"
      ;;
    esac
    case "$mode" in active|interactive) ;; *) mode="$last_mode" ;; esac
    [ -n "$heading" ] || heading="$last_heading"
    [ -n "$detail" ] || detail="$last_detail"
    last_pct="$pct"; last_mode="$mode"; last_heading="$heading"; last_detail="$detail"
    if [ "$mode" = interactive ]; then
      sleep 1
      continue
    fi
    filled=$(( pct * width / 100 ))
    bar=""; i=0
    while [ "$i" -lt "$width" ]; do
      if [ "$i" -lt "$filled" ]; then bar="$bar#"; else bar="$bar."; fi
      i=$(( i + 1 ))
    done
    {
      clear
      echo
      echo "  ============= GOOGLE PLAY APK DOWNLOADER ============="
      echo
      printf '  %s\n' "$heading"
      echo
      printf '  [%s] %3d%%\n' "$bar" "$pct"
      echo
      printf '  %s\n' "$detail"
      echo
      echo "  First use is slower because the private browser is installed once."
      echo "  Do not turn off the device."
      echo
      echo "  ========================================================"
    } >/dev/tty1 2>/dev/null
    sleep 1
  done
}

run_apk_setup() { # [apk paths...]
  local progress="$GAMEDIR/install_progress.txt" setup_pid setup_rc
  : > "$progress" 2>/dev/null || true
  SHOW_MSG_SLEEP=1 show_msg "Found APK - extracting game files." \
                            "This takes a few minutes, please wait..."
  MCPE_PROGRESS_FILE="$progress" MCPE_ALLOW_UNTESTED="${MCPE_ALLOW_UNTESTED:-0}" \
    bash "$GAMEDIR/setup_apk.sh" "$@" &
  setup_pid=$!
  draw_install_progress "$setup_pid" "$progress"
  wait "$setup_pid"
  setup_rc=$?
  rm -f "$progress"
  if [ "$setup_rc" -eq 0 ]; then
    refresh_installed_version
    show_msg "Game installed!" "You can now delete the APK from the apk folder."
    return 0
  fi
  if [ -s "$GAMEDIR/setup_error.txt" ]; then
    mapfile -t err_lines < "$GAMEDIR/setup_error.txt"
    show_msg "APK setup failed:" "${err_lines[@]}"
  else
    show_msg "APK extraction FAILED." \
             "See log.txt in the minecraftbedrock folder."
  fi
  return 1
}

has_installer_input() {
  find "$GAMEDIR/apk" -maxdepth 1 -type f \
    \( -iname '*.apk' -o -iname '*.apks' -o -iname '*.apkm' \
       -o -iname '*.xapk' -o -iname '*.zip' \) -print -quit 2>/dev/null |
    grep -q .
}

if has_installer_input; then
  if ! has_installed_version; then
    run_apk_setup || exit 1
  elif [ -z "$MENU_LOVE_TXT" ] && [ -z "${MCVER_OVERRIDE:-}" ]; then
    run_apk_setup || echo "Continuing with the already-installed versions."
  fi
fi

if ! has_installed_version && [ -z "$MENU_LOVE_TXT" ]; then
  show_msg "No Minecraft version installed." \
           "Copy your own APK/APKM/APKS/XAPK (arm64, or arm32 for RK3326" \
           "devices like the R36S) into:" \
           "ports/minecraftbedrock-data/apk/" \
           "then launch this port again."
  exit 1
fi

latest_installed_version() {
  local selected candidate
  if has_installed_version; then
    printf '%s\n' "$MCPE_LATEST_INSTALLED"
    return 0
  fi
  selected="$(python3 "$GAMEDIR/version_env.py" "$GAMEDIR" --select-latest 2>/dev/null)" &&
    [ -n "$selected" ] && { printf '%s\n' "$selected"; return 0; }
  # Compatibility fallback for an old payload that predates metadata.  The
  # normal path above always prefers a validated version.json and therefore
  # cannot choose an alphabetically-late, misnamed extraction over it.
  if sort -V </dev/null >/dev/null 2>&1; then
    for candidate in "$GAMEDIR/versions"/*; do
      [ -d "$candidate" ] && printf '%s\n' "$(basename "$candidate")"
    done | sort -V | tail -1
  else
    for candidate in "$GAMEDIR/versions"/*; do
      [ -d "$candidate" ] && printf '%s\n' "$(basename "$candidate")"
    done | sort | tail -1
  fi
}

# --- Frontend handling for the menu ---------------------------------------------
# muOS owns its framebuffer outside a launched port, so its frontend needs a
# local handoff. Knulli already pauses ES input/display through emulatorlauncher
# while a port runs; trying to stop its service from inside that child blocks
# for 20 seconds and leaves the ES wrapper alive beside the port.
ES_INIT=/etc/init.d/S31emulationstation
MENU_STOPPED_ES=0
MENU_STOPPED_MUOS=0
menu_stop_frontend() {
  # PortMaster/CFW launch wrappers normally own frontend suspension. The old
  # internal kill/restart path is retained only as an explicit compatibility
  # escape hatch for direct/manual launches.
  [ "${MCPE_MANAGE_FRONTEND:-0}" = 1 ] || return
  pidof sway >/dev/null 2>&1 && return
  if mcpe_is_cfw muos; then
    if pidof frontend.sh >/dev/null 2>&1 || pidof muxlaunch >/dev/null 2>&1; then
      MENU_STOPPED_MUOS=1
      $ESUDO killall -q frontend.sh muxlaunch 2>/dev/null || true
      sleep 1
    fi
    return
  fi
  mcpe_is_knulli && return
  [ -x "$ES_INIT" ] || return
  pidof emulationstation >/dev/null 2>&1 || return
  MENU_STOPPED_ES=1
  $ESUDO "$ES_INIT" stop
}
menu_restore_frontend() {
  if [ -n "${MCPE_MENU_HANDOFF_PID:-}" ]; then
    kill "$MCPE_MENU_HANDOFF_PID" 2>/dev/null || true
    wait "$MCPE_MENU_HANDOFF_PID" 2>/dev/null || true
    unset MCPE_MENU_HANDOFF_PID
  fi
  if [ "$MENU_STOPPED_MUOS" = 1 ]; then
    MENU_STOPPED_MUOS=0
    (
      unset GAMEDIR MCVER_OVERRIDE MCPE_DATA_ROOT_OVERRIDE MCPE_IS_MUOS MCPE_CFW
      if [ -x /opt/muos/script/mux/frontend.sh ]; then
        setsid /opt/muos/script/mux/frontend.sh launcher </dev/null >/dev/null 2>&1 &
      elif command -v frontend.sh >/dev/null 2>&1; then
        setsid frontend.sh launcher </dev/null >/dev/null 2>&1 &
      fi
    )
    return
  fi
  [ "$MENU_STOPPED_ES" = 1 ] || return
  MENU_STOPPED_ES=0
  (
    unset GAMEDIR MCVER_OVERRIDE MCPE_DATA_ROOT_OVERRIDE
    setsid $ESUDO "$ES_INIT" start </dev/null >/dev/null 2>&1
  )
}
trap menu_restore_frontend EXIT

# --- Launcher menu ---------------------------------------------------------------
# Loop: install/delete actions return to the menu; play/exit leave it.
MCPE_MENU_STATUS=""

valid_plain_name() { # no path tricks in names coming back from the menu
  case "$1" in ""|.|..|.*|*/*|*\\*) return 1 ;; esac
  return 0
}

menu_do_install() {
  local names=() n
  if [ -f "$CONFDIR/install_request.txt" ]; then
    while IFS= read -r n; do
      valid_plain_name "$n" && [ -f "$GAMEDIR/apk/$n" ] &&
        names+=("$GAMEDIR/apk/$n")
    done < "$CONFDIR/install_request.txt"
    rm -f "$CONFDIR/install_request.txt"
  fi
  if run_apk_setup "${names[@]}"; then
    MCPE_MENU_STATUS="Installed OK - you can delete the APK (X)"
  else
    MCPE_MENU_STATUS="Install failed - see log.txt"
  fi
}

refresh_downloader_menu_state() {
  export MCPE_DOWNLOADER_SUPPORTED=0 MCPE_DOWNLOADER_SESSION=0 MCPE_DOWNLOADER_RUNTIME=0
  if [ "${MCPE_HOST_ARCH:-}" = aarch64 ] && [ "${MCPE_HOST_PROFILE:-}" = h700 ] &&
     mcpe_is_cfw knulli batocera; then
    export MCPE_DOWNLOADER_SUPPORTED=1
  fi
  [ -s "$MCPE_SHARED_ROOT/downloader/playdl.conf" ] &&
    [ -s "$MCPE_SHARED_ROOT/downloader/token_cache.conf" ] &&
    export MCPE_DOWNLOADER_SESSION=1
  if [ -x "$MCPE_SHARED_ROOT/downloader/runtime/root/usr/bin/mcpelauncher-ui-qt" ] ||
     [ -x /userdata/roms/ports/.mcpe_appimage64/squashfs-root/usr/bin/mcpelauncher-ui-qt ]; then
    export MCPE_DOWNLOADER_RUNTIME=1
  fi
}

apk_quick_state() {
  local path lower row rows=""
  for path in "$GAMEDIR/apk/"*; do
    [ -f "$path" ] || continue
    lower="${path,,}"
    case "$lower" in *.apk|*.apks|*.apkm|*.xapk|*.zip) ;; *) continue ;; esac
    row="$(stat -c '%n|%s|%Y' "$path" 2>/dev/null)" || return 1
    rows+="$row"$'\n'
  done
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$rows" | sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$rows" | openssl dgst -sha256 | sed 's/^.*= //'
  else
    return 1
  fi
}

refresh_apk_groups() {
  local quick cached="" marker="$CONFDIR/apk-groups/.quick-input-state"
  quick="$(apk_quick_state)" || quick=""
  [ -f "$marker" ] && read -r cached <"$marker"
  if [ -n "$quick" ] && [ "$quick" = "$cached" ] &&
     [ -f "$CONFDIR/apk-groups/index.tsv" ]; then
    return 0
  fi
  python3 "$GAMEDIR/apk_groups.py" "$GAMEDIR/apk" "$CONFDIR/apk-groups" \
    2>>"$GAMEDIR/logs/launcher.log" || return 1
  quick="$(apk_quick_state)" || quick=""
  [ -n "$quick" ] && printf '%s\n' "$quick" >"$marker" 2>/dev/null || true
}

menu_do_download() { # version-code[:arm64|armhf]
  local request="$1" code abi result="$CONFDIR/downloader-result.txt"
  local progress="$GAMEDIR/downloader_progress.txt" downloader_pid downloader_rc
  local progress_ack=""
  local names=() n
  case "$request" in
    *:*) code="${request%%:*}"; abi="${request#*:}" ;;
    *) code="$request"; abi=arm64 ;;
  esac
  case "$code" in ''|*[!0-9]*) MCPE_MENU_STATUS="Invalid download choice"; return ;; esac
  case "$abi" in arm64|armhf) ;; *) MCPE_MENU_STATUS="Invalid download architecture"; return ;; esac
  if ! awk -F '\t' -v code="$code" -v abi="$abi" \
      '$1 == code && $2 == abi { found=1 } END { exit(found ? 0 : 1) }' \
      "$GAMEDIR/downloader/version_catalog.tsv" 2>/dev/null; then
    MCPE_MENU_STATUS="Version is not in the downloadable catalog"
    return
  fi
  if [ "${MCPE_DOWNLOADER_SUPPORTED:-0}" != 1 ]; then
    MCPE_MENU_STATUS="Downloader prototype requires RG34XXSP/H700 + Knulli"
    return
  fi
  SHOW_MSG_SLEEP=1 show_msg "Opening the optional Google Play downloader..." \
                            "Passwords stay inside Google's sign-in page."
  printf '1|active|Starting Google Play downloader|Checking optional sign-in components.\n' \
    >"$progress" 2>/dev/null || true
  if [ -n "${LOVE_RUN:-}" ] && [ -d "$GAMEDIR/downloader/progress-ui" ] &&
     ! pidof sway >/dev/null 2>&1; then
    progress_ack="$GAMEDIR/config/downloader-interactive.ack"
    rm -f "$progress_ack"
  fi
  MCPE_DOWNLOADER_STATE="$MCPE_SHARED_ROOT/downloader" \
  MCPE_DOWNLOADER_RESULT="$result" MCPE_DOWNLOADER_PROGRESS="$progress" \
  MCPE_DOWNLOADER_INTERACTIVE_ACK="$progress_ack" \
    bash "$GAMEDIR/downloader/run.sh" download "$code" "$abi" &
  downloader_pid=$!
  draw_downloader_progress "$downloader_pid" "$progress" "$progress_ack"
  wait "$downloader_pid"
  downloader_rc=$?
  rm -f "$progress"
  if [ "$downloader_rc" -ne 0 ]; then
    MCPE_MENU_STATUS="Download failed or cancelled - see logs/downloader.log"
    return
  fi
  if [ -f "$result" ]; then
    while IFS= read -r n; do
      valid_plain_name "$n" && [ -f "$GAMEDIR/apk/$n" ] && names+=("$GAMEDIR/apk/$n")
    done <"$result"
    rm -f "$result"
  fi
  if [ "${#names[@]}" -eq 0 ]; then
    MCPE_MENU_STATUS="Download finished but produced no validated APK set"
  elif MCPE_ALLOW_UNTESTED=1 run_apk_setup "${names[@]}"; then
    MCPE_MENU_STATUS="Downloaded, validated and installed $abi build from Google Play"
  else
    MCPE_MENU_STATUS="APK downloaded; automatic install failed - see log.txt"
  fi
}

run_launcher_menu() {
  [ -n "$MENU_LOVE_TXT" ] || return 1
  # shellcheck disable=SC1090
  source "$MENU_LOVE_TXT" 2>/dev/null || return 1
  [ -n "${LOVE_RUN:-}" ] || return 1
  if command -v pm_platform_helper >/dev/null 2>&1 &&
     [ -n "${LOVE_BINARY:-}" ]; then
    pm_platform_helper "$LOVE_BINARY" >/dev/null 2>&1 || true
  fi
  mcpe_startup_mark "menu runtime prepared"
  export MCPE_GAMEDIR="$GAMEDIR"
  export MCPE_MENU_EXIT_ON_PLAY=0
  # On Knulli/fbdev the last presented frame remains visible after LOVE exits.
  # Reap the menu before Weston starts so two Mali surfaces can never swap to
  # the panel at the same time. Composited CFWs retain the live handoff path.
  mcpe_is_knulli && export MCPE_MENU_EXIT_ON_PLAY=1
  local action arg love_status love_pid menu_gptk_pid menu_controller_file menu_controller_config
  local menu_ready_watch_pid
  menu_controller_file="${SDL_GAMECONTROLLERCONFIG_FILE:-/tmp/gamecontrollerdb.txt}"
  menu_controller_config="${sdl_controllerconfig:-}"
  # LOVE consumes SDL raw indices, while mcpelauncher's linux-gamepad backend
  # consumes a different evdev-derived index space. Never feed the game map to
  # LOVE: it makes the face buttons and shoulders appear unrelated.
  if [ "${MCPE_HOST_PROFILE:-}" = h700 ] &&
     [ -s "$GAMEDIR/controls/rg34xxsp.sdl.gamecontrollerdb.txt" ]; then
    menu_controller_file="$GAMEDIR/controls/rg34xxsp.sdl.gamecontrollerdb.txt"
    menu_controller_config="$(awk 'NF && $1 !~ /^#/' "$menu_controller_file")"
  fi
  while :; do
    # APK inspection can be expensive for large split sets. Keep the frontend
    # visible until the cached inventory is ready, then hand display/input to
    # LOVE immediately before it draws.
    refresh_apk_groups || true
    mcpe_startup_mark "APK inventory ready"
    refresh_downloader_menu_state
    menu_stop_frontend
    : > "$CONFDIR/menu_action.txt"
    rm -f "$CONFDIR/menu_first_frame.txt"
    export MCPE_MENU_STATUS
    menu_gptk_pid=""
    # LOVE receives mapped SDL gamepad events directly on H700. Running a
    # keyboard bridge at the same time races the same button through two input
    # paths (for example printed A as both select and Escape), so use the
    # bridge only on older profiles that actually need keyboard emulation.
    if [ -n "${GPTOKEYB:-}" ] && [ "${MCPE_HOST_PROFILE:-}" != h700 ]; then
      SDL_GAMECONTROLLERCONFIG="$menu_controller_config" \
      SDL_GAMECONTROLLERCONFIG_FILE="$menu_controller_file" \
        $GPTOKEYB "love.${DEVICE_ARCH:-aarch64}" >/dev/null 2>&1 &
      menu_gptk_pid=$!
    fi
    SDL_AUDIODRIVER=dummy \
      SDL_GAMECONTROLLERCONFIG="$menu_controller_config" \
      SDL_GAMECONTROLLERCONFIG_FILE="$menu_controller_file" \
      $LOVE_RUN "$GAMEDIR/menu" &
    love_pid=$!
    mcpe_startup_mark "LOVE process started"
    (
      while kill -0 "$love_pid" 2>/dev/null; do
        if [ -s "$CONFDIR/menu_first_frame.txt" ]; then
          mcpe_startup_mark "menu first frame"
          exit 0
        fi
        sleep 0.02
      done
    ) &
    menu_ready_watch_pid=$!
    action=""
    # Normal actions write the protocol file and exit. Play writes it but
    # deliberately keeps the fullscreen Launching screen alive for handoff.
    while kill -0 "$love_pid" 2>/dev/null; do
      action="$(sed -n 1p "$CONFDIR/menu_action.txt" 2>/dev/null)"
      [ -n "$action" ] && break
      sleep 0.05
    done
    if [ "$action" = play ] && kill -0 "$love_pid" 2>/dev/null; then
      if [ "${MCPE_MENU_EXIT_ON_PLAY:-0}" = 1 ]; then
        wait "$love_pid"
        love_status=$?
      else
        export MCPE_MENU_HANDOFF_PID="$love_pid"
        love_status=0
      fi
    else
      wait "$love_pid"
      love_status=$?
    fi
    if [ -n "$menu_gptk_pid" ]; then
      kill "$menu_gptk_pid" 2>/dev/null || true
      wait "$menu_gptk_pid" 2>/dev/null || true
    fi
    kill "$menu_ready_watch_pid" 2>/dev/null || true
    wait "$menu_ready_watch_pid" 2>/dev/null || true
    [ -n "$action" ] || action="$(sed -n 1p "$CONFDIR/menu_action.txt" 2>/dev/null)"
    arg="$(sed -n 2p "$CONFDIR/menu_action.txt" 2>/dev/null)"
    case "$action" in
      play)
        valid_plain_name "$arg" && [ -d "$GAMEDIR/versions/$arg" ] &&
          export MCVER_OVERRIDE="$arg"
        return 0
        ;;
      install)
        menu_do_install
        ;;
      install_untested)
        # The menu already put the risk to the user and they said yes.
        MCPE_ALLOW_UNTESTED=1 menu_do_install
        ;;
      download_apk)
        menu_do_download "$arg"
        ;;
      downloader_signout)
        if MCPE_DOWNLOADER_STATE="$MCPE_SHARED_ROOT/downloader" \
             bash "$GAMEDIR/downloader/run.sh" signout; then
          MCPE_MENU_STATUS="Saved Google session removed from this device"
        else
          MCPE_MENU_STATUS="Could not remove the saved Google session"
        fi
        ;;
      downloader_remove)
        if MCPE_DOWNLOADER_STATE="$MCPE_SHARED_ROOT/downloader" \
             bash "$GAMEDIR/downloader/run.sh" remove; then
          MCPE_MENU_STATUS="Optional downloader runtime removed; APKs kept"
        else
          MCPE_MENU_STATUS="Could not remove the optional downloader runtime"
        fi
        ;;
      delete)
        if valid_plain_name "$arg" && [ -d "$GAMEDIR/versions/$arg" ]; then
          rm -rf "$GAMEDIR/versions/$arg"
          refresh_installed_version
          MCPE_MENU_STATUS="Deleted version $arg"
        fi
        ;;
      delete_apk)
        if valid_plain_name "$arg" && [ -f "$GAMEDIR/apk/$arg" ]; then
          rm -f "$GAMEDIR/apk/$arg"
          MCPE_MENU_STATUS="Deleted $arg"
        fi
        ;;
      delete_apk_group)
        if valid_plain_name "$arg" && [ -f "$CONFDIR/apk-groups/$arg.txt" ]; then
          deleted=0
          while IFS= read -r apk_name; do
            if valid_plain_name "$apk_name" && [ -f "$GAMEDIR/apk/$apk_name" ]; then
              rm -f "$GAMEDIR/apk/$apk_name"
              deleted=$((deleted + 1))
            fi
          done <"$CONFDIR/apk-groups/$arg.txt"
          MCPE_MENU_STATUS="Deleted $deleted APK file(s)"
        fi
        ;;
      backup_create)
        mkdir -p "$GAMEDIR/backups"
        bk="backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        SHOW_MSG_SLEEP=1 show_msg "Creating backup..." \
                                  "(worlds, settings, profiles)"
        backup_args=(-C "$MCPE_SHARED_ROOT" profiles)
        [ -f "$GAMEDIR/config/settings.cfg" ] && \
          backup_args+=(-C "$GAMEDIR" config/settings.cfg)
        if tar czf "$GAMEDIR/backups/$bk.part" "${backup_args[@]}" 2>/dev/null &&
           mv "$GAMEDIR/backups/$bk.part" "$GAMEDIR/backups/$bk"; then
          MCPE_MENU_STATUS="Backup created ($(du -h "$GAMEDIR/backups/$bk" 2>/dev/null | cut -f1))"
        else
          rm -f "$GAMEDIR/backups/$bk.part"
          MCPE_MENU_STATUS="Backup FAILED - check free space"
        fi
        ;;
      backup_restore)
        if valid_plain_name "$arg" && [ -f "$GAMEDIR/backups/$arg" ]; then
          SHOW_MSG_SLEEP=1 show_msg "Restoring backup..." "$arg"
          if tar tzf "$GAMEDIR/backups/$arg" 2>/dev/null | \
               awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad}' &&
             tar xzf "$GAMEDIR/backups/$arg" -C "$MCPE_SHARED_ROOT" profiles 2>/dev/null &&
             { ! tar tzf "$GAMEDIR/backups/$arg" 2>/dev/null | grep -qx 'config/settings.cfg' ||
               { mkdir -p "$GAMEDIR/config" &&
                 tar xzf "$GAMEDIR/backups/$arg" -C "$GAMEDIR" config/settings.cfg 2>/dev/null; }; }; then
            MCPE_MENU_STATUS="Backup restored"
          else
            MCPE_MENU_STATUS="Restore FAILED - see log.txt"
          fi
        fi
        ;;
      backup_delete)
        if valid_plain_name "$arg" && [ -f "$GAMEDIR/backups/$arg" ]; then
          rm -f "$GAMEDIR/backups/$arg"
          MCPE_MENU_STATUS="Backup deleted"
        fi
        ;;
      install_rgds)
        echo "Menu: RGDS edition install chosen."
        if [ -f "$GAMEDIR/update_port.sh" ]; then
          updater_tmp="${TMPDIR:-/tmp}/minecraftbedrock-update-$$.sh"
          cp -f "$GAMEDIR/update_port.sh" "$updater_tmp"
          MCPE_UPDATE_TARGET_EDITION=minecraftbedrock.rgds \
          MCPE_ENTRY_DIR="$PORTDIR" MCPE_GAMEDIR="$GAMEDIR" \
            bash "$updater_tmp" || true
          rm -f "$updater_tmp"
        fi
        exit 0
        ;;
      support_bundle)
        if [ -x "$GAMEDIR/create_support_bundle.sh" ]; then
          bundle="$(GAMEDIR="$GAMEDIR" bash "$GAMEDIR/create_support_bundle.sh")"
          MCPE_MENU_STATUS="Support bundle saved: $(basename "$bundle")"
        else
          MCPE_MENU_STATUS="Support bundle helper is missing"
        fi
        ;;
      controller_test)
        SHOW_MSG_SLEEP=1 show_msg "Controller test: press buttons and move both sticks for 8 seconds."
        if python3 "$GAMEDIR/controller_diag.py" --seconds 8 >"$GAMEDIR/logs/controller-test.txt" 2>&1; then
          MCPE_MENU_STATUS="Controller test saved to logs/controller-test.txt"
        else
          MCPE_MENU_STATUS="Controller test found no readable gamepad; see its log"
        fi
        ;;
      update)
        # Self-update. The updater overwrites this very script, which is
        # safe only because this whole function was parsed before running:
        # run the updater from a copy (its own file also gets overwritten;
        # it protects itself the same way), then exit WITHOUT reading
        # anything further from this file. The EXIT trap restores the
        # frontend that the menu phase stopped.
        echo "Menu: update chosen."
        if [ -f "$GAMEDIR/update_port.sh" ]; then
          updater_tmp="${TMPDIR:-/tmp}/minecraftbedrock-update-$$.sh"
          cp -f "$GAMEDIR/update_port.sh" "$updater_tmp"
          MCPE_ENTRY_DIR="$PORTDIR" MCPE_GAMEDIR="$GAMEDIR" \
            bash "$updater_tmp" || true
          rm -f "$updater_tmp"
        else
          show_msg "Updater missing (update_port.sh)." \
                   "Re-install the port from the release zip."
        fi
        exit 0
        ;;
      exit)
        echo "Menu: exit chosen."
        exit 0
        ;;
      *)
        [ -s "$CONFDIR/menu_error.txt" ] &&
          { echo "menu error:"; cat "$CONFDIR/menu_error.txt"; }
        echo "Menu unavailable (love exit $love_status) - using defaults."
        return 1
        ;;
    esac
  done
}
if [ -n "$MENU_LOVE_TXT" ]; then
  mcpe_stage menu
  if ! run_launcher_menu; then
    {
      printf 'launcher menu failed at %s\n' "$(date 2>/dev/null || true)"
      [ -s "$CONFDIR/menu_error.txt" ] && cat "$CONFDIR/menu_error.txt"
      tail -n 80 "$GAMEDIR/logs/launcher.log" 2>/dev/null || true
    } >"$GAMEDIR/logs/menu-failure.log" 2>/dev/null || true
    show_msg "Minecraft launcher menu failed." \
             "Minecraft was NOT started with hidden defaults." \
             "See logs/menu-failure.log or create a support bundle."
    exit 2
  fi
elif [ "$MENU_WANTED" = 1 ]; then
  echo "Launcher menu runtime unavailable; using legacy autoplay (set MCPE_MENU=1 to require the menu)."
fi

if [ "${MCPE_REDIRECT_RGDS:-0}" = 1 ]; then
  show_msg "This is an RGDS dual-screen device." \
           "Install 'Minecraft Bedrock RGDS' from the release page." \
           "The lightweight standard edition will not start here."
  exit 2
fi

# The menu can delete versions; re-check before launching.
if ! has_installed_version; then
  show_msg "No Minecraft version installed anymore." \
           "Use Get APK from Google Play, or copy a Bedrock APK into" \
           "ports/minecraftbedrock-data/apk/ and install it from the menu."
  exit 1
fi

# --- Persisted settings (written by the menu's Settings screen) ------------------
# Only whitelisted keys are consumed and every value is validated, so a
# hand-edited settings.cfg cannot inject anything. Explicit env pins win over
# the saved settings.
SETTINGS_VERSION=""
apply_settings() {
  local f="$CONFDIR/settings.cfg" k v
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      version)
        v="${v//[!A-Za-z0-9._+ -]/}"
        SETTINGS_VERSION="$v"
        continue
        ;;
    esac
    v="${v//[!A-Za-z0-9]/}"
    case "$k" in
      fps_cap)
        case "$v" in ''|0|*[!0-9]*) ;; *)
          [ -z "${MCPE_MAX_FPS:-}" ] && export MCPE_MAX_FPS="$v" ;;
        esac ;;
      render_distance) # stored in chunks; the game option is in blocks
        case "$v" in ''|0|*[!0-9]*) ;; *)
          [ -z "${MCPE_RENDER_DISTANCE:-}" ] && export MCPE_RENDER_DISTANCE="$((v * 16))" ;;
        esac ;;
      abi)
        case "$v" in arm64|armhf)
          [ -z "${MCPE_ABI_OVERRIDE:-}" ] && export MCPE_ABI_OVERRIDE="$v" ;;
        esac ;;
      ui_scale)
        case "$v" in 1|2|3)
          [ -z "${MCPE_UI_DENSITY_SCALE:-}" ] && export MCPE_UI_DENSITY_SCALE="$v" ;;
        esac ;;
      vsync)
        case "$v" in 0|1)
          [ -z "${MCPE_VSYNC:-}" ] && export MCPE_VSYNC="$v" ;;
        esac ;;
      perf_mode)
        case "$v" in 0|1)
          [ -z "${MCPE_PERFORMANCE_MODE:-}" ] && export MCPE_PERFORMANCE_MODE="$v" ;;
        esac ;;
      options_tuning)
        case "$v" in 0|1)
          [ -z "${MCPE_PERFORMANCE_OPTIONS:-}" ] && export MCPE_PERFORMANCE_OPTIONS="$v" ;;
        esac ;;
      measure_fps)
        case "$v" in 0|1)
          [ -z "${MCPE_MEASURE_FPS:-}" ] && export MCPE_MEASURE_FPS="$v" ;;
        esac ;;
      update_channel)
        case "$v" in stable|testing)
          printf '%s\n' "$v" >"$CONFDIR/update_channel" ;;
        esac ;;
    esac
  done < "$f"
}
apply_settings

set_seed_option() {
  local options_file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$options_file" 2>/dev/null; then
    sed -i "s#^${key}:.*#${key}:${value}#" "$options_file"
  else
    echo "${key}:${value}" >>"$options_file"
  fi
}

seed_116_options() {
  local options_file default_options
  options_file="$MCPE_DATA_ROOT_OVERRIDE/mcpelauncher/games/com.mojang/minecraftpe/options.txt"
  [ ! -f "$options_file" ] || return

  mkdir -p "$(dirname "$options_file")"
  default_options="$GAMEDIR/profiles/default/mcpelauncher/games/com.mojang/minecraftpe/options.txt"
  if [ -f "$default_options" ]; then
    cp "$default_options" "$options_file"
  else
    : >"$options_file"
  fi

  set_seed_option "$options_file" gfx_vsync 0
  set_seed_option "$options_file" gfx_msaa 1
  set_seed_option "$options_file" gfx_fancyskies 0
  set_seed_option "$options_file" gfx_toggleclouds 0
  set_seed_option "$options_file" gfx_smoothlighting 0
  set_seed_option "$options_file" gfx_transparentleaves 0
}

# Version precedence: custom/menu pin > remembered menu selection > registry recommendation.
MCVER="${MCVER_OVERRIDE:-}"
if [ -z "$MCVER" ] && [ -n "$SETTINGS_VERSION" ] &&
   [ -d "$GAMEDIR/versions/$SETTINGS_VERSION" ]; then
  if [ -f "$GAMEDIR/versions/$SETTINGS_VERSION/version.json" ] ||
     ! compgen -G "$GAMEDIR/versions/*/version.json" >/dev/null; then
    MCVER="$SETTINGS_VERSION"
  else
    echo "Ignoring remembered unverified version '$SETTINGS_VERSION'; a metadata-backed install is available."
  fi
fi
MCVER="${MCVER:-$(latest_installed_version)}"
export MCVER_OVERRIDE="$MCVER"
VERSION_ENV="$(python3 "$GAMEDIR/version_env.py" "$GAMEDIR" "$GAMEDIR/versions/$MCVER" 2>&1)" || {
  echo "Version metadata validation failed: $VERSION_ENV"
  exit 1
}
eval "$VERSION_ENV"
export MCPE_VERSION_METADATA MCPE_BEDROCK_VERSION_NAME MCPE_BEDROCK_VERSION_CODE
export MCPE_BEDROCK_ABI_LABEL MCPE_COMPAT_STATUS MCPE_PROFILE_CLASS
export MCPE_GAME_LIBRARY_SHA256 MCPE_RENDERER_PROFILE MCPE_RECOMMENDATION
export MCPE_COMPAT_WARNING
export MCPE_PATCH_EDUMODE MCPE_PATCH_HTTP_RESOLVE MCPE_COMPACTION_AVAILABLE
if [ "${MCPE_COMPAT_STATUS:-best_effort}" = unsupported ]; then
  echo "Selected Bedrock build is unsupported by the compatibility registry."
  exit 1
fi
if [ -n "${MCPE_COMPAT_WARNING:-}" ]; then
  echo "Compatibility warning: $MCPE_COMPAT_WARNING"
fi
if [ "${MCPE_DISABLE_AUTO_COMPACTION:-0}" = 1 ] &&
   [ "${MCPE_COMPACTION_AVAILABLE:-0}" != 1 ]; then
  echo "Auto-compaction patch requested but unavailable for this metadata; disabling it."
  export MCPE_DISABLE_AUTO_COMPACTION=0
fi
if [ -z "${MCPE_DATA_ROOT_OVERRIDE:-}" ] && [ "${MCPE_PROFILE_CLASS:-default}" = legacy_1_16 ]; then
  export MCPE_DATA_ROOT_OVERRIDE="$GAMEDIR/profiles/$MCVER"
  # Architecture-specific defaults are applied after run_bedrock.sh selects
  # the usable client.  In particular, do not pre-fill the 64-bit defaults
  # here and accidentally suppress the low-memory R36S/armhf preset.
  seed_116_options
else
  export MCPE_DATA_ROOT_OVERRIDE="${MCPE_DATA_ROOT_OVERRIDE:-$GAMEDIR/profiles/default}"
fi
mkdir -p "$MCPE_DATA_ROOT_OVERRIDE"

bash "$GAMEDIR/run_bedrock.sh"
status=$?

[ "$status" -eq 0 ] && mcpe_mark_migration_success

if command -v pm_finish >/dev/null 2>&1; then
  pm_finish || true
fi

# Reached only on an orderly return from the launch path. Any other outcome
# leaves the breadcrumb on the stage that was still in progress.
mcpe_stage done

exit "$status"
