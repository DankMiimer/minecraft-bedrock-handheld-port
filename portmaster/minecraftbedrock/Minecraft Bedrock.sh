#!/bin/bash
# Minecraft Bedrock Edition (mcpelauncher, EGLUT/Weston) — manual install.
# Target: ARM handhelds on Knulli/muOS H700, ROCKNIX/Aurknix Mali devices,
# and RK3326/R36S-class PortMaster setups via the 32-bit SDL path.
# Reference gates: RG34XX-SP/H700 and R36S/armhf. RGDS uses its own edition.
#
# Place this script and the minecraftbedrock/ folder together in your ports
# directory. muOS split installs are also supported:
#   /roms/Ports/Minecraft Bedrock.sh + /ports/minecraftbedrock/

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
if type get_controls >/dev/null 2>&1; then
  get_controls 2>/dev/null || true
fi
export sdl_controllerconfig="${sdl_controllerconfig:-}"

# The sourced PortMaster files can clobber SCRIPT_DIR (seen on Knulli:
# pick_game_dir then resolved "/minecraftbedrock"). Restore it from the
# copy taken before sourcing.
SCRIPT_DIR="$PORTDIR"

is_muos() {
  local cfw_lower
  cfw_lower="$(printf '%s' "${CFW_NAME:-}" | tr '[:upper:]' '[:lower:]')"
  case "$cfw_lower" in *muos*) return 0 ;; esac
  [ -d /opt/muos ] || [ -d /mnt/mmc/MUOS ] || [ -d /mnt/sdcard/MUOS ] ||
    [ -e /opt/muos/script/var/global/device.txt ]
}

if is_muos; then
  export MCPE_IS_MUOS=1
fi

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
# shellcheck disable=SC1091
source "$GAMEDIR/lib/common.sh" || { echo "Missing common runtime helpers."; exit 1; }
mcpe_load_edition "$GAMEDIR/edition.json" || { echo "Invalid edition manifest."; exit 1; }
# shellcheck disable=SC1091
source "$GAMEDIR/lib/migrate_data.sh" || exit 1
mcpe_migrate_shared_data || { echo "Shared-data migration failed without overwriting user data."; exit 1; }
python3 "$GAMEDIR/migrate_version_metadata.py" "$GAMEDIR" ||
  echo "Legacy version metadata backfill failed; affected versions remain best effort."
# shellcheck disable=SC1091
source "$GAMEDIR/lib/platform.sh" || exit 1
mcpe_apply_platform_profile "$CONFDIR/resolved_host.env" || { echo "Host capability probe failed."; exit 1; }

> "$GAMEDIR/logs/launcher.log" && ln -sfn "logs/launcher.log" "$GAMEDIR/log.txt" 2>/dev/null || true
exec > >(tee -a "$GAMEDIR/logs/launcher.log") 2>&1
cd "$GAMEDIR"
echo "Port dir: $PORTDIR"
echo "Game dir: $GAMEDIR"
echo "Edition: $MCPE_EDITION_ID"
echo "Shared data: $MCPE_SHARED_ROOT"
echo "CFW: ${CFW_NAME:-unknown} profile=${MCPE_HOST_PROFILE:-generic} backend=${MCPE_GRAPHICS_BACKEND_RESOLVED:-unknown}"

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

import_legacy_r36s_versions() {
  [ -z "$(ls -A "$GAMEDIR/versions" 2>/dev/null)" ] || return 0
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
    [ "$imported" = 1 ] && show_msg "Legacy versions imported."
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
if [ "${MCPE_MENU:-auto}" != 0 ] && [ -z "${MCVER_OVERRIDE:-}" ] &&
   [ -f "$GAMEDIR/menu/main.lua" ]; then
  MENU_LOVE_TXT="$(find_love_txt)" || MENU_LOVE_TXT=""
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

run_apk_setup() { # [apk paths...]
  local progress="$GAMEDIR/install_progress.txt" setup_pid setup_rc
  : > "$progress" 2>/dev/null || true
  SHOW_MSG_SLEEP=1 show_msg "Found APK - extracting game files." \
                            "This takes a few minutes, please wait..."
  MCPE_PROGRESS_FILE="$progress" bash "$GAMEDIR/setup_apk.sh" "$@" &
  setup_pid=$!
  draw_install_progress "$setup_pid" "$progress"
  wait "$setup_pid"
  setup_rc=$?
  rm -f "$progress"
  if [ "$setup_rc" -eq 0 ]; then
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

if ls "$GAMEDIR/apk/"*.apk >/dev/null 2>&1; then
  if [ -z "$(ls -A "$GAMEDIR/versions" 2>/dev/null)" ]; then
    run_apk_setup || exit 1
  elif [ -z "$MENU_LOVE_TXT" ] && [ -z "${MCVER_OVERRIDE:-}" ]; then
    run_apk_setup || echo "Continuing with the already-installed versions."
  fi
fi

if [ -z "$(ls -A "$GAMEDIR/versions" 2>/dev/null)" ]; then
  show_msg "No Minecraft version installed." \
           "Copy your own Bedrock APK (arm64, or arm32 for RK3326" \
           "devices like the R36S) into:" \
           "ports/minecraftbedrock-data/apk/" \
           "then launch this port again."
  exit 1
fi

latest_installed_version() {
  local selected
  selected="$(python3 "$GAMEDIR/version_env.py" "$GAMEDIR" --select-latest 2>/dev/null)" &&
    [ -n "$selected" ] && { printf '%s\n' "$selected"; return 0; }
  # Compatibility fallback for an old payload that predates metadata.  The
  # normal path above always prefers a validated version.json and therefore
  # cannot choose an alphabetically-late, misnamed extraction over it.
  if sort -V </dev/null >/dev/null 2>&1; then
    ls "$GAMEDIR/versions" | sort -V | tail -1
  else
    ls "$GAMEDIR/versions" | sort | tail -1
  fi
}

# --- Frontend handling for the menu ---------------------------------------------
# Knulli ES and the muOS frontend hold the framebuffer and input nodes; they
# must be out of the way while the LOVE menu draws. Under sway (ROCKNIX) the
# menu is a normal window and nothing needs stopping. The downstream launch
# scripts stop/restart only what THEY stopped, so when the menu phase stops
# the frontend it is also the one to restore it — via the EXIT trap, which
# covers both the exit-from-menu and the after-game paths.
ES_INIT=/etc/init.d/S31emulationstation
MENU_STOPPED_ES=0
MENU_STOPPED_MUOS=0
menu_stop_frontend() {
  pidof sway >/dev/null 2>&1 && return
  if [ "${MCPE_IS_MUOS:-0}" = 1 ]; then
    if pidof frontend.sh >/dev/null 2>&1 || pidof muxlaunch >/dev/null 2>&1; then
      MENU_STOPPED_MUOS=1
      $ESUDO killall -q frontend.sh muxlaunch 2>/dev/null || true
      sleep 1
    fi
    return
  fi
  [ -x "$ES_INIT" ] || return
  pidof emulationstation >/dev/null 2>&1 || return
  MENU_STOPPED_ES=1
  $ESUDO "$ES_INIT" stop
}
menu_restore_frontend() {
  if [ "$MENU_STOPPED_MUOS" = 1 ]; then
    MENU_STOPPED_MUOS=0
    (
      unset GAMEDIR MCVER_OVERRIDE MCPE_DATA_ROOT_OVERRIDE MCPE_IS_MUOS
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

run_launcher_menu() {
  [ -n "$MENU_LOVE_TXT" ] || return 1
  # shellcheck disable=SC1090
  source "$MENU_LOVE_TXT" 2>/dev/null || return 1
  [ -n "${LOVE_RUN:-}" ] || return 1
  export MCPE_GAMEDIR="$GAMEDIR"
  local action arg love_status
  while :; do
    # APK inspection can be expensive for large split sets. Keep the frontend
    # visible until the cached inventory is ready, then hand display/input to
    # LOVE immediately before it draws.
    python3 "$GAMEDIR/apk_groups.py" "$GAMEDIR/apk" "$CONFDIR/apk-groups" 2>>"$GAMEDIR/logs/launcher.log" || true
    menu_stop_frontend
    : > "$CONFDIR/menu_action.txt"
    export MCPE_MENU_STATUS
    [ -n "${GPTOKEYB:-}" ] && $GPTOKEYB "love.${DEVICE_ARCH:-aarch64}" >/dev/null 2>&1 &
    SDL_AUDIODRIVER=dummy \
      SDL_GAMECONTROLLERCONFIG="${sdl_controllerconfig:-}" \
      $LOVE_RUN "$GAMEDIR/menu"
    love_status=$?
    [ -n "${GPTOKEYB:-}" ] && $ESUDO kill -9 "$(pidof gptokeyb)" 2>/dev/null
    action="$(sed -n 1p "$CONFDIR/menu_action.txt" 2>/dev/null)"
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
      delete)
        if valid_plain_name "$arg" && [ -d "$GAMEDIR/versions/$arg" ]; then
          rm -rf "$GAMEDIR/versions/$arg"
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
run_launcher_menu || true

if [ "${MCPE_REDIRECT_RGDS:-0}" = 1 ]; then
  show_msg "This is an RGDS dual-screen device." \
           "Install 'Minecraft Bedrock RGDS' from the release page." \
           "The lightweight standard edition will not start here."
  exit 2
fi

# The menu can delete versions; re-check before launching.
if [ -z "$(ls -A "$GAMEDIR/versions" 2>/dev/null)" ]; then
  show_msg "No Minecraft version installed anymore." \
           "Copy a Bedrock APK into ports/minecraftbedrock-data/apk/" \
           "and install it from the launcher menu."
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
  export MCPE_RENDER_DISTANCE="${MCPE_RENDER_DISTANCE:-64}"
  export MCPE_MAX_FPS="${MCPE_MAX_FPS:-40}"
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

exit "$status"
