#!/bin/bash
# Optional on-device Google Play downloader prototype for RG34XXSP/Knulli.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GAMEDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE="${MCPE_DOWNLOADER_STATE:-${MCPE_SHARED_ROOT:-$GAMEDIR}/downloader}"
RESULT_FILE="${MCPE_DOWNLOADER_RESULT:-$GAMEDIR/config/downloader-result.txt}"
APKDIR="$GAMEDIR/apk"
BIN_DIR="$SCRIPT_DIR/bin"
LOGDIR="$GAMEDIR/logs"
LOG="$LOGDIR/downloader.log"
PROGRESS_FILE="${MCPE_DOWNLOADER_PROGRESS:-}"
INTERACTIVE_ACK="${MCPE_DOWNLOADER_INTERACTIVE_ACK:-}"
APPROOT=""
WESTON_DIR=/tmp/weston
MESA_DIR=/tmp/mesa
# Firmwares differ in what they leave in /usr/lib. muOS ships no 64-bit
# libcom_err.so.2 -- Knulli does -- and the AppImage's libgssapi_krb5.so.2
# pulls it in, so the Qt sign-in helper exited with "cannot open shared object
# file" before it drew anything. The pinned Weston package already carries that
# library. Append this LAST everywhere so it can only ever fill a genuine gap
# and can never shadow a system or AppImage library.
WESTON_FALLBACK_LIBS="$WESTON_DIR/lib_aarch64"
SYSTEM_XKB_LINK=/usr/share/X11/xkb
SYSTEM_XKB_LINK_CREATED=0
CREDENTIAL_MANIFEST="$SCRIPT_DIR/credential-artifacts.txt"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime.conf"
mkdir -p "$STATE" "$LOGDIR"
chmod 700 "$STATE" 2>/dev/null || true
[ -f "$BIN_DIR/gplaydl" ] && chmod 700 "$BIN_DIR/gplaydl" 2>/dev/null || true
[ -f "$BIN_DIR/gplayver" ] && chmod 700 "$BIN_DIR/gplayver" 2>/dev/null || true
[ -f "$SCRIPT_DIR/preload-entry.sh" ] && chmod 700 "$SCRIPT_DIR/preload-entry.sh" 2>/dev/null || true

log() {
  printf '%s\n' "$*" | tee -a "$LOG"
}

# Private, atomic status protocol consumed by Minecraft Bedrock.sh:
# percent|active|heading|detail, or percent|interactive|heading|detail while
# Weston/Google owns the display. No account identifiers or tokens are written.
progress() { # percent mode heading detail
  local pct="$1" mode="$2" heading="$3" detail="$4" temporary
  [ -n "$PROGRESS_FILE" ] || return 0
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  [ "$pct" -le 100 ] || pct=100
  heading="${heading//$'\n'/ }"; heading="${heading//|/-}"
  detail="${detail//$'\n'/ }"; detail="${detail//|/-}"
  temporary="$PROGRESS_FILE.tmp.$$"
  printf '%s|%s|%s|%s\n' "$pct" "$mode" "$heading" "$detail" >"$temporary" || return 0
  chmod 600 "$temporary" 2>/dev/null || true
  mv -f "$temporary" "$PROGRESS_FILE" 2>/dev/null || rm -f "$temporary"
}

wait_for_interactive_handoff() {
  local count=0
  [ -n "$INTERACTIVE_ACK" ] || return 0
  while [ ! -f "$INTERACTIVE_ACK" ] && [ "$count" -lt 300 ]; do
    sleep 0.1
    count=$((count + 1))
  done
  if [ ! -f "$INTERACTIVE_ACK" ]; then
    log "Timed out waiting for the progress surface to release the display."
    return 1
  fi
  rm -f "$INTERACTIVE_ACK"
}

fail() {
  log "Downloader: $*"
  return 1
}

cleanup_system_xkb_link() {
  if [ "$SYSTEM_XKB_LINK_CREATED" = 1 ] && [ -L "$SYSTEM_XKB_LINK" ] &&
     [ "$(readlink "$SYSTEM_XKB_LINK" 2>/dev/null)" = "$WESTON_DIR/share/X11/xkb" ]; then
    rm -f "$SYSTEM_XKB_LINK"
    rmdir /usr/share/X11 2>/dev/null || true
  fi
  SYSTEM_XKB_LINK_CREATED=0
}

# Google account data lives only in the private state directory, and only in
# the paths credential-artifacts.txt declares. Reading that shared manifest
# here keeps run.sh and scripts/check_downloader_policy.py from ever drifting
# apart about where a token can land.
credential_paths() { # transient|session|dir
  local want="$1" kind path
  [ -r "$CREDENTIAL_MANIFEST" ] || return 0
  while read -r kind path _; do
    case "$kind" in ''|'#'*) continue ;; esac
    case "$path" in ''|/*|.|..|*/../*|*/..|../*) continue ;; esac
    case "$want.$kind" in
      transient.transient|session.transient|session.session|dir.dir)
        printf '%s\n' "$path" ;;
    esac
  done <"$CREDENTIAL_MANIFEST"
}

# An interrupted sign-in must not leave Google's one-shot token on the card.
remove_transient_credentials() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && rm -f "$STATE/$name"
  done < <(credential_paths transient)
  return 0
}

on_exit() {
  remove_transient_credentials
  cleanup_system_xkb_link
}

trap on_exit EXIT
trap 'exit 143' HUP INT TERM

is_supported() {
  case "$(uname -m 2>/dev/null)" in aarch64|arm64) ;; *) return 1 ;; esac
  [ "${MCPE_HOST_PROFILE:-h700}" = h700 ] || return 1
  # The launcher resolves the firmware once and exports it, so prefer that over
  # re-reading os-release. muOS joined the list on 2026-08-24: it is the same
  # H700 hardware as the Knulli reference, and it reaches the same Mali display
  # stack -- the only thing it lacked was PortMaster's Mesa package, which
  # ensure_mesa now fetches for itself.
  case "${MCPE_CFW:-}" in
    knulli|batocera|muos) return 0 ;;
    ?*) return 1 ;;
  esac
  # No launcher in front of us: fall back to reading the firmware directly.
  [ -r /etc/os-release ] || return 1
  grep -Eqi 'knulli|batocera|muos|mustardos' /etc/os-release
}

safe_remove_tree() {
  local target="$1"
  case "$target" in
    "$STATE"/runtime|"$STATE"/runtime/.extract-*|\
    "$STATE"/runtime/qt-plugin-view|"$STATE"/.download-*) ;;
    *) log "Refusing unsafe generated-directory cleanup: $target"; return 1 ;;
  esac
  [ -e "$target" ] || return 0
  [ -d "$target" ] && [ ! -L "$target" ] || return 1
  find "$target" -depth -delete
}

sha_ok() { # path digest size
  local path="$1" digest="$2" expected_size="$3" actual
  [ -f "$path" ] || return 1
  actual="$(wc -c <"$path" 2>/dev/null | tr -d ' ')"
  [ "$actual" = "$expected_size" ] || return 1
  printf '%s  %s\n' "$digest" "$path" | sha256sum -c - >/dev/null 2>&1
}

fetch_verified() { # url sha size destination description
  local url="$1" sha="$2" size="$3" destination="$4" description="$5"
  local temporary="$destination.part"
  if sha_ok "$destination" "$sha" "$size"; then return 0; fi
  if [ -e "$destination" ]; then
    mv "$destination" "$destination.bad.$(date +%Y%m%d-%H%M%S)" || return 1
  fi
  rm -f "$temporary"
  log "Downloading optional $description..."
  case "$description" in
    *browser*) progress 10 active "Downloading sign-in browser" "One-time 141 MiB download; this can take several minutes." ;;
    *keyboard*) progress 43 active "Adding the on-screen keyboard" "Downloading the small verified Qt keyboard component." ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "$temporary" "$url" || {
      rm -f "$temporary"; return 1;
    }
  else
    wget -O "$temporary" "$url" || { rm -f "$temporary"; return 1; }
  fi
  if ! sha_ok "$temporary" "$sha" "$size"; then
    rm -f "$temporary"
    log "$description failed its pinned size/SHA-256 check."
    return 1
  fi
  mv "$temporary" "$destination"
}

find_app_root() {
  local candidate
  for candidate in \
    "${MCPE_DOWNLOADER_APPROOT_OVERRIDE:-/nonexistent}" \
    "$STATE/runtime/root" \
    /userdata/roms/ports/.mcpe_appimage64/squashfs-root
  do
    if [ -x "$candidate/usr/bin/mcpelauncher-ui-qt" ] &&
       [ -f "$candidate/usr/lib/libprotobuf.so.32" ] &&
       [ -d "$candidate/usr/qml/QtQuick/VirtualKeyboard" ]; then
      APPROOT="$candidate"
      return 0
    fi
  done
  return 1
}

ensure_app_root() {
  local runtime="$STATE/runtime" image="$STATE/runtime/mcpe-launcher.AppImage"
  local staging="$STATE/runtime/.extract-$$"
  progress 5 active "Checking sign-in components" "Looking for the optional Google browser runtime."
  if find_app_root; then
    progress 24 active "Sign-in browser ready" "Using the verified browser already saved on this device."
    return 0
  fi
  mkdir -p "$runtime"
  fetch_verified "$APPIMAGE_URL" "$APPIMAGE_SHA256" "$APPIMAGE_SIZE" \
    "$image" "Google sign-in browser runtime (141 MiB)" || return 1
  chmod 700 "$image"
  mkdir "$staging" || return 1
  log "Extracting the optional sign-in browser (about 550 MiB installed)..."
  progress 26 active "Installing sign-in browser" "Extracting about 550 MiB once; do not turn off the device."
  if ! (cd "$staging" && "$image" --appimage-extract >/dev/null 2>>"$LOG"); then
    safe_remove_tree "$staging" || true
    return 1
  fi
  if [ ! -x "$staging/squashfs-root/usr/bin/mcpelauncher-ui-qt" ]; then
    safe_remove_tree "$staging" || true
    return 1
  fi
  if [ -e "$runtime/root" ]; then
    safe_remove_tree "$staging" || true
    log "An incomplete optional runtime already exists; remove it from the downloader menu first."
    return 1
  fi
  mv "$staging/squashfs-root" "$runtime/root" || return 1
  rmdir "$staging" 2>/dev/null || true
  APPROOT="$runtime/root"
  progress 40 active "Sign-in browser installed" "The one-time browser setup is complete."
}

ensure_keyboard_plugin() {
  local runtime="$STATE/runtime" package="$STATE/runtime/qt-keyboard.deb"
  local plugin="$STATE/runtime/qt-plugins/platforminputcontexts/libqtvirtualkeyboardplugin.so"
  if [ -f "$plugin" ]; then
    progress 46 active "On-screen keyboard ready" "Using the saved controller-friendly keyboard."
    return 0
  fi
  mkdir -p "$runtime"
  fetch_verified "$KEYBOARD_DEB_URL" "$KEYBOARD_DEB_SHA256" "$KEYBOARD_DEB_SIZE" \
    "$package" "on-screen keyboard plugin" || return 1
  python3 "$SCRIPT_DIR/deb_extract.py" "$package" "$plugin" >>"$LOG" 2>&1
  progress 46 active "On-screen keyboard ready" "Keyboard component installed and verified."
}

ensure_weston() {
  local squash
  progress 49 active "Preparing the Google window" "Checking PortMaster's display runtime."
  if [ -f "$WESTON_DIR/westonwrap.sh" ]; then return 0; fi
  squash="${WESTON_SQUASH:-}"
  if [ -z "$squash" ]; then
    squash="$(bash "$GAMEDIR/ensure_runtime.sh" weston_pkg_0.2.aarch64)" || return 1
  fi
  mkdir -p "$WESTON_DIR"
  ${ESUDO:-} mount "$squash" "$WESTON_DIR" >>"$LOG" 2>&1 || return 1
  [ -f "$WESTON_DIR/westonwrap.sh" ]
}

ensure_system_xkb_link() {
  local source="$WESTON_DIR/share/X11/xkb"
  [ -f "$source/rules/evdev" ] || return 1
  if [ -f "$SYSTEM_XKB_LINK/rules/evdev" ]; then
    return 0
  fi
  if [ -L "$SYSTEM_XKB_LINK" ]; then
    [ "$(readlink "$SYSTEM_XKB_LINK" 2>/dev/null)" = "$source" ] || return 1
    SYSTEM_XKB_LINK_CREATED=1
    return 0
  fi
  [ ! -e "$SYSTEM_XKB_LINK" ] || return 1
  mkdir -p /usr/share/X11 || return 1
  ln -s "$source" "$SYSTEM_XKB_LINK" || return 1
  SYSTEM_XKB_LINK_CREATED=1
}

ensure_mesa() {
  local squash="${MESA_SQUASH:-}" candidate
  progress 56 active "Preparing browser graphics" "Checking Mesa and XWayland support."
  [ -f "$MESA_DIR/lib/aarch64-linux-gnu/libGLX_mesa.so.0" ] && return 0
  mkdir -p "$MESA_DIR" || return 1
  if grep -qs " $MESA_DIR " /proc/mounts 2>/dev/null; then
    log "The Mesa runtime is mounted but incomplete. Reboot and try again."
    return 1
  fi
  if [ -z "$squash" ]; then
    for candidate in \
      /userdata/system/.local/share/PortMaster/libs/mesa_pkg_0.1.squashfs \
      "${controlfolder:-/nonexistent}/libs/mesa_pkg_0.1.squashfs" \
      "${controlfolder:-/nonexistent}/libs/mesa_pkg_0.1.aarch64.squashfs"
    do
      if [ -f "$candidate" ]; then squash="$candidate"; break; fi
    done
  fi
  # Knulli and Batocera ship this package through PortMaster. muOS does not --
  # its PortMaster libs directory is empty -- so fetch the same pinned runtime
  # the Weston step already downloads, verified against compat/runtime-index.json.
  if [ -z "$squash" ]; then
    squash="$(bash "$GAMEDIR/ensure_runtime.sh" mesa_pkg_0.1.aarch64)" || {
      log "The Mesa support package is missing and could not be downloaded."
      return 1
    }
  fi
  [ -n "$squash" ] && [ -f "$squash" ] || {
    log "The Mesa support package is missing."
    return 1
  }
  ${ESUDO:-} mount "$squash" "$MESA_DIR" >>"$LOG" 2>&1 || return 1
  [ -f "$MESA_DIR/lib/aarch64-linux-gnu/libGLX_mesa.so.0" ]
}

ensure_gui_gl_bridge() {
  local bridge="$STATE/runtime/qt-gl4es"
  [ ! -L "$bridge" ] || { log "Unsafe optional GL bridge path."; return 1; }
  mkdir -p "$bridge" || return 1
  [ -f "$WESTON_DIR/lib_aarch64/graphics/gl4es_glxpass/libGL.so.1" ] || return 1
  [ -f "$WESTON_DIR/lib_aarch64/graphics/crusty_glx/libGLX.so.0" ] || return 1
  ln -sfn "$WESTON_DIR/lib_aarch64/graphics/gl4es_glxpass/libGL.so.1" \
    "$bridge/libOpenGL.so.0" || return 1
  ln -sfn "$WESTON_DIR/lib_aarch64/graphics/gl4es_glxpass/libGL.so.1" \
    "$bridge/libGL.so.1" || return 1
  ln -sfn "$WESTON_DIR/lib_aarch64/graphics/crusty_glx/libGLX.so.0" \
    "$bridge/libGLX.so.0" || return 1
  # Keep Qt on PortMaster's matching X11/XCB ABI without putting all of
  # weston_pkg ahead of the AppImage's Qt libraries.
  for candidate in libX11.so.6 libX11-xcb.so.1 libxcb.so.1 libSM.so.6 libICE.so.6; do
    [ -f "$WESTON_DIR/lib_aarch64/$candidate" ] || return 1
    ln -sfn "$WESTON_DIR/lib_aarch64/$candidate" "$bridge/$candidate" || return 1
  done
}

ensure_qt_plugin_view() {
  local view="$STATE/runtime/qt-plugin-view" candidate name
  local keyboard="$STATE/runtime/qt-plugins/platforminputcontexts/libqtvirtualkeyboardplugin.so"
  safe_remove_tree "$view" || return 1
  mkdir -p "$view/xcbglintegrations" "$view/platforminputcontexts" || return 1
  for candidate in "$APPROOT/usr/plugins"/*; do
    [ -d "$candidate" ] || continue
    name="$(basename "$candidate")"
    case "$name" in xcbglintegrations|platforminputcontexts) continue ;; esac
    ln -s "$candidate" "$view/$name" || return 1
  done
  [ -f "$APPROOT/usr/plugins/xcbglintegrations/libqxcb-glx-integration.so" ] || return 1
  [ -f "$keyboard" ] || return 1
  ln -s "$APPROOT/usr/plugins/xcbglintegrations/libqxcb-glx-integration.so" \
    "$view/xcbglintegrations/libqxcb-glx-integration.so" || return 1
  ln -s "$keyboard" \
    "$view/platforminputcontexts/libqtvirtualkeyboardplugin.so" || return 1
}

ensure_qt_launcher_view() {
  local root="$STATE/runtime/qt-launcher" source="$APPROOT/usr/bin/mcpelauncher-ui-qt"
  local target="$STATE/runtime/qt-launcher/bin/mcpelauncher-ui-qt"
  local config="$STATE/runtime/qt-launcher/bin/qt.conf"
  mkdir -p "$root/bin" || return 1
  if ! cmp -s "$source" "$target"; then
    cp "$source" "$target.new" || return 1
    chmod 700 "$target.new"
    mv "$target.new" "$target" || return 1
  fi
  {
    printf '%s\n' '[Paths]'
    printf 'Prefix=%s\n' "$APPROOT/usr"
    printf 'Plugins=%s\n' "$STATE/runtime/qt-plugin-view"
    printf 'Qml2Imports=%s\n' "$APPROOT/usr/qml"
    printf 'Translations=%s\n' "$APPROOT/usr/translations"
    printf 'LibraryExecutables=%s\n' "$APPROOT/usr/libexec"
  } >"$config.new" || return 1
  chmod 600 "$config.new"
  mv "$config.new" "$config" || return 1
}

# Crusty reads the libraries it needs from $CRUSTY_LIBSDL and $CRUSTY_LIBEGL.
# With either unset it falls back to symlinking a bare soname into /tmp, a
# relative target that can never resolve there, so every SDL entry point in it
# stays NULL and the first call -- SDL_SetHint -- crashes the sign-in helper
# before it draws anything. westonwrap fills those variables in only for its
# own crusty graphics modes; this port asks for llvmpipe and preloads crusty
# itself, so resolving them is this script's job.
find_shared_library() { # soname...
  local candidate resolved directory
  for candidate in "$@"; do
    if [ -x "$WESTON_DIR/tools/findlib" ]; then
      resolved="$("$WESTON_DIR/tools/findlib" "$candidate" 2>/dev/null | tail -n 1)"
      if [ -n "$resolved" ] && [ -f "$resolved" ]; then
        printf '%s\n' "$resolved"
        return 0
      fi
    fi
    for directory in /usr/lib64 /usr/lib/aarch64-linux-gnu /usr/lib /lib64 \
      "$WESTON_FALLBACK_LIBS"; do
      if [ -f "$directory/$candidate" ]; then
        printf '%s\n' "$directory/$candidate"
        return 0
      fi
    done
  done
  return 1
}

# Crusty caches whatever it resolved as /tmp/<VARIABLE>64.so and never replaces
# an existing one, so a single run that resolved nothing leaves a dangling
# symlink behind that breaks every later run until the device is rebooted.
# Replace any link that does not already point at the library resolved here,
# and leave a real file alone -- that is somebody else's deliberate override.
refresh_crusty_link() { # variable path
  local link="/tmp/${1}64.so"
  [ -L "$link" ] || return 0
  [ "$(readlink -f "$link" 2>/dev/null)" = "$(readlink -f "$2" 2>/dev/null)" ] && return 0
  rm -f "$link"
}

run_google_gui() {
  local width height gui_rc gui_preload crusty_sdl crusty_egl
  ensure_app_root || return 1
  ensure_keyboard_plugin || return 1
  ensure_weston || return 1
  ensure_system_xkb_link || {
    log "The bundled keyboard layout data could not be exposed to Google sign-in."
    return 1
  }
  ensure_mesa || return 1
  ensure_gui_gl_bridge || return 1
  ensure_qt_plugin_view || return 1
  ensure_qt_launcher_view || return 1
  crusty_sdl="${CRUSTY_LIBSDL:-}"
  [ -n "$crusty_sdl" ] ||
    crusty_sdl="$(find_shared_library libSDL2-2.0.so.0 libSDL2-2.0.so \
      libSDL2.so.0 libSDL2.so)" || {
      log "This device has no 64-bit SDL2 library, which Google sign-in needs."
      return 1
    }
  crusty_egl="${CRUSTY_LIBEGL:-}"
  [ -n "$crusty_egl" ] ||
    crusty_egl="$(find_shared_library libEGL.so.1 libEGL.so)" || {
      log "This device has no 64-bit EGL library, which Google sign-in needs."
      return 1
    }
  refresh_crusty_link CRUSTY_LIBSDL "$crusty_sdl"
  refresh_crusty_link CRUSTY_LIBEGL "$crusty_egl"
  read -r width height < <(fbset 2>/dev/null | awk '/geometry/ {print $2, $3; exit}')
  width="${width:-720}" height="${height:-480}"
  export MCPE_DOWNLOADER_APPROOT="$APPROOT" MCPE_DOWNLOADER_STATE="$STATE"
  rm -f "$STATE/gui-result"
  cd "$SCRIPT_DIR" || return 1
  # The compatibility shim must precede GL4ES so its guarded early
  # glGetString query wins symbol resolution during WebEngine startup.
  gui_preload="$SCRIPT_DIR/lib/libqt-xcb-glx-compat.so"
  gui_preload="$gui_preload:$WESTON_DIR/lib_aarch64/graphics/gl4es_glxpass/libGL.so.1"
  gui_preload="$gui_preload:$WESTON_DIR/lib_aarch64/graphics/crusty_glx/libcrusty.so"
  log "Opening Google sign-in. D-pad changes focus, A selects, B goes back, shoulders scroll."
  progress 66 interactive "Opening Google sign-in" "Google handles your password and phone approval in the next window."
  wait_for_interactive_handoff || return 1
  WP_32BIT=0 DISPLAY_WIDTH="$width" DISPLAY_HEIGHT="$height" \
  SDL_VIDEODRIVER="${MCPE_DOWNLOADER_SDL_DRIVER:-mali}" \
  CRUSTY_LIBSDL="$crusty_sdl" CRUSTY_LIBEGL="$crusty_egl" \
  CRUSTY_GL4ES=1 \
  LIBGL_ES=2 LIBGL_GL=21 LIBGL_NOTEST=1 LIBGL_NOCLEAN=1 \
  WESTON_HEADLESS_WIDTH="$width" WESTON_HEADLESS_HEIGHT="$height" \
  WRAPPED_PRELOAD="$gui_preload" \
  WRAPPED_LIBRARY_PATH="$STATE/runtime/qt-gl4es:$APPROOT/usr/lib:/usr/lib:$WESTON_FALLBACK_LIBS" \
    "$WESTON_DIR/westonwrap.sh" headless noop kiosk llvmpipe \
      env LD_LIBRARY_PATH="$STATE/runtime/qt-gl4es:$APPROOT/usr/lib:/usr/lib:/lib64:$WESTON_FALLBACK_LIBS" \
      MCPE_DOWNLOADER_APPROOT="$APPROOT" MCPE_DOWNLOADER_STATE="$STATE" \
      MCPE_DOWNLOADER_UI="$STATE/runtime/qt-launcher/bin/mcpelauncher-ui-qt" \
      MCPE_DOWNLOADER_SCRIPT_DIR="$SCRIPT_DIR" \
      bash "$SCRIPT_DIR/preload-entry.sh" >>"$LOG" 2>&1
  gui_rc=$?
  [ -f "$STATE/gui-result" ] || gui_rc=1
  rm -f "$STATE/gui-result"
  "$WESTON_DIR/westonwrap.sh" cleanup >>"$LOG" 2>&1 || true
  progress 74 active "Sign-in approved" "Closing Google's window and preparing the Play session."
  return "$gui_rc"
}

prepare_device_profile() { # arm64|armhf
  local abi="$1" name source target
  case "$abi" in
    arm64) name=device-arm64.conf ;;
    armhf) name=device-armhf.conf ;;
    *) log "Unknown Google Play architecture: $abi"; return 1 ;;
  esac
  source="$SCRIPT_DIR/$name"
  target="$STATE/$name"
  [ -s "$source" ] || { log "Missing downloader profile: $name"; return 1; }
  cp "$source" "$target.new" || return 1
  chmod 600 "$target.new"
  mv "$target.new" "$target"
}

session_ready() {
  [ -s "$STATE/playdl.conf" ] && [ -s "$STATE/token_cache.conf" ]
}

ensure_session() {
  local rc auth_input="$STATE/google-access-input"
  if session_ready; then
    progress 76 active "Google Play session ready" "Using the saved private session on this device."
    return 0
  fi
  [ -x "$BIN_DIR/gplayver" ] || { log "The ARM64 downloader helper is missing."; return 1; }
  rm -f "$STATE/playdl.conf" "$STATE/token_cache.conf" "$auth_input"
  run_google_gui || return 1
  find_app_root || return 1
  prepare_device_profile arm64 || return 1
  [ -s "$auth_input" ] || { log "Google sign-in returned no access token."; return 1; }
  log "Completing the secure Google Play sign-in..."
  progress 77 active "Finishing Google Play sign-in" "Securely exchanging Google's approval for a saved Play session."
  (
    cd "$STATE" || exit 1
    timeout 180 env LD_LIBRARY_PATH="$APPROOT/usr/lib:/usr/lib:$WESTON_FALLBACK_LIBS" \
      "$BIN_DIR/gplayver" --interactive --device "$STATE/device-arm64.conf" \
      --accept-tos --app com.mojang.minecraftpe <"$auth_input"
  ) >>"$LOG" 2>&1
  rc=$?
  rm -f "$auth_input"
  if [ "$rc" -ne 0 ] || ! session_ready; then
    rm -f "$STATE/playdl.conf" "$STATE/token_cache.conf"
    log "Google Play could not finish the access-token exchange. Sign in again."
    return 1
  fi
  progress 80 active "Google Play session ready" "Approval complete; starting the selected APK download."
}

valid_download_request() { # version_code abi
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in arm64|armhf) ;; *) return 1 ;; esac
  awk -F '\t' -v code="$1" -v abi="$2" \
    '$1 == code && $2 == abi { found=1 } END { exit(found ? 0 : 1) }' \
    "$SCRIPT_DIR/version_catalog.tsv" 2>/dev/null
}

publish_download() { # staging code abi
  local staging="$1" code="$2" abi="$3"
  local list="$staging/validated.txt" previous="$staging/previous"
  local name old moved=()
  progress 95 active "Validating downloaded APKs" "Checking package, version, signer, splits and requested architecture."
  python3 "$SCRIPT_DIR/validate_download.py" "$staging" "$code" "$abi" >"$list" 2>>"$LOG" || return 1
  [ -s "$list" ] || return 1
  mkdir "$previous" || return 1
  for old in "$APKDIR/minecraft-$code"*.apk; do
    [ -f "$old" ] || continue
    mv "$old" "$previous/" || return 1
  done
  while IFS= read -r name; do
    case "$name" in ""|.*|*/*|*\\*) continue ;; esac
    if ! mv "$staging/$name" "$APKDIR/$name"; then
      for name in "${moved[@]}"; do rm -f "$APKDIR/$name"; done
      for old in "$previous"/*.apk; do [ -f "$old" ] && mv "$old" "$APKDIR/"; done
      return 1
    fi
    moved+=("$name")
  done <"$list"
  : >"$RESULT_FILE.new"
  chmod 600 "$RESULT_FILE.new"
  for name in "${moved[@]}"; do printf '%s\n' "$name" >>"$RESULT_FILE.new"; done
  mv "$RESULT_FILE.new" "$RESULT_FILE"
  safe_remove_tree "$staging"
}

download_version() {
  local code="$1" abi="${2:-arm64}" profile progress_pct line
  local staging="$STATE/.download-$code-$$" output rc
  valid_download_request "$code" "$abi" || {
    log "Unsupported prototype request: version code $code / $abi"; return 2;
  }
  is_supported || { log "On-device download is currently limited to H700 devices on Knulli, Batocera or muOS."; return 2; }
  [ -x "$BIN_DIR/gplaydl" ] || { log "The ARM64 downloader helper is missing."; return 1; }
  progress 2 active "Starting Google Play downloader" "Checking the optional components and saved session."
  rm -f "$RESULT_FILE" "$RESULT_FILE.new"
  ensure_app_root || return 1
  ensure_session || return 1
  prepare_device_profile "$abi" || return 1
  profile="$STATE/device-$abi.conf"
  mkdir -p "$APKDIR"
  mkdir "$staging" || return 1
  output="$staging/minecraft-$code.apk"
  log "Downloading Minecraft version code $code ($abi) from Google Play..."
  progress 82 active "Downloading Minecraft APKs" "Requested $abi build $code from Google Play."
  (
    cd "$STATE" || exit 1
    LD_LIBRARY_PATH="$APPROOT/usr/lib:/usr/lib:$WESTON_FALLBACK_LIBS" \
      "$BIN_DIR/gplaydl" --login-no-verify --device "$profile" \
      --accept-tos --app com.mojang.minecraftpe --app-version "$code" --output "$output"
  ) 2>&1 | tr '\r' '\n' | (
    last_progress_pct=-1
    while IFS= read -r line; do
    if [[ "$line" =~ Downloaded[[:space:]]+([0-9]+)% ]]; then
      progress_pct="${BASH_REMATCH[1]}"
      [ "$progress_pct" -le 100 ] || progress_pct=100
      [ "$progress_pct" = "$last_progress_pct" ] && continue
      last_progress_pct="$progress_pct"
      printf '%s\n' "$line" >>"$LOG"
      # gplaydl reports each split independently and resets to 0 for the next
      # file. Keep the milestone bar monotonic and label this honestly as the
      # current APK file's percentage.
      progress 84 active "Downloading Minecraft APKs" \
        "Current APK file: $progress_pct% ($abi build $code)."
    elif [ -n "$line" ]; then
      printf '%s\n' "$line" >>"$LOG"
    fi
    done
  )
  rc=${PIPESTATUS[0]}
  # Upstream sometimes exits non-zero after completing all files; the strict
  # manifest, signer, version and ARM64 validation below is authoritative.
  if publish_download "$staging" "$code" "$abi"; then
    log "Validated Google Play APK set saved in the port's apk folder."
    progress 100 active "APK download complete" "Validated files are saved; installation starts next."
    return 0
  fi
  safe_remove_tree "$staging" || true
  log "The Google Play download was incomplete or invalid (helper exit $rc)."
  return 1
}

sign_out() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && rm -f "$STATE/$name"
  done < <(credential_paths session)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -d "$STATE/$name" ] && [ ! -L "$STATE/$name" ]; then
      find "$STATE/$name" -depth -delete
    fi
  done < <(credential_paths dir)
  log "Saved Google session removed from this device."
}

remove_optional_runtime() {
  sign_out || true
  safe_remove_tree "$STATE/runtime" || return 1
  log "Optional sign-in browser and keyboard removed; downloaded APKs were kept."
}

case "${1:-}" in
  supported) is_supported ;;
  status) session_ready ;;
  download) download_version "${2:-}" "${3:-arm64}" ;;
  signout) sign_out ;;
  remove) remove_optional_runtime ;;
  *) echo "usage: run.sh supported|status|download VERSION_CODE [arm64|armhf]|signout|remove" >&2; exit 2 ;;
esac
