#!/bin/bash
# Runs inside PortMaster's Weston/XWayland session. Never print credentials.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPROOT="${MCPE_DOWNLOADER_APPROOT:?missing GUI runtime}"
STATE="${MCPE_DOWNLOADER_STATE:?missing downloader state}"
UI="${MCPE_DOWNLOADER_SIGNIN_UI:-$SCRIPT_DIR/bin/mcpe-signin}"
QML="${MCPE_DOWNLOADER_SIGNIN_QML:-$SCRIPT_DIR/signin.qml}"
CAPTURE="$STATE/google-signin-result.json"
AUTH_INPUT="$STATE/google-access-input"
GUI_RESULT="$STATE/gui-result"

export HOME="$STATE/home"
export XDG_CONFIG_HOME="$STATE/xdg/config"
export XDG_CACHE_HOME="$STATE/xdg/cache"
export XDG_DATA_HOME="$STATE/xdg/data"
export XDG_DATA_DIRS="$APPROOT/usr/share:/usr/local/share:/usr/share"
export PATH="$APPROOT/usr/bin:$PATH"
export QT_QPA_PLATFORM=xcb
export QT_QPA_PLATFORM_PLUGIN_PATH="$APPROOT/usr/plugins/platforms"
export QT_PLUGIN_PATH="$STATE/runtime/qt-plugin-view"
export QML2_IMPORT_PATH="$APPROOT/usr/qml"
export QML_IMPORT_PATH="$APPROOT/usr/qml"
export QTWEBENGINEPROCESS_PATH="$APPROOT/usr/libexec/QtWebEngineProcess"
export QTWEBENGINE_RESOURCES_PATH="$APPROOT/usr/resources"
export QTWEBENGINE_LOCALES_PATH="$APPROOT/usr/translations/qtwebengine_locales"
export XKB_CONFIG_ROOT="${MCPE_DOWNLOADER_XKB_ROOT:-/tmp/weston/share/X11/xkb}"
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_CHROMIUM_FLAGS="${MCPE_DOWNLOADER_CHROMIUM_FLAGS:---no-sandbox --disable-gpu-sandbox}"
export QT_QUICK_BACKEND=opengl
export QT_XCB_GL_INTEGRATION=xcb_glx
export QSG_RHI_BACKEND=opengl
export QSG_RENDER_LOOP=basic
export QT_IM_MODULE=qtvirtualkeyboard
export QT_SCALE_FACTOR="${MCPE_DOWNLOADER_QT_SCALE:-1}"

mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
rm -f "$GUI_RESULT" "$CAPTURE" "$AUTH_INPUT"

cleanup() {
  rm -f "$CAPTURE"
  # A cancelled or crashed sign-in must not leave Google's one-shot token
  # behind; only a completed handoff keeps the exchange input.
  [ -f "$GUI_RESULT" ] || rm -f "$AUTH_INPUT"
}

trap cleanup EXIT
trap 'exit 143' HUP INT TERM

[ -x "$UI" ] && [ -f "$QML" ] || {
  echo "The on-device Google sign-in helper is missing." >&2
  exit 1
}

if [ "${MCPE_DOWNLOADER_GDB:-0}" = 1 ]; then
  : >"$STATE/graphics-gdb.log"
  chmod 600 "$STATE/graphics-gdb.log"
  env -u LD_PRELOAD gdb -q -batch \
    -ex "set environment LD_PRELOAD ${MCPE_GUI_PRELOAD:-}" \
    -ex run -ex "thread apply all bt 20" --args "$UI" "$QML" "$CAPTURE" \
    >"$STATE/graphics-gdb.log" 2>&1 &
elif [ "${MCPE_DOWNLOADER_GRAPHICS_DIAGNOSTIC:-0}" = 1 ]; then
  : >"$STATE/graphics-diagnostic.log"
  chmod 600 "$STATE/graphics-diagnostic.log"
  LD_PRELOAD="${MCPE_GUI_PRELOAD:-}" QSG_INFO=1 \
    "$UI" "$QML" "$CAPTURE" >"$STATE/graphics-diagnostic.log" 2>&1 &
else
  # Qt's diagnostics go to a private, owner-only file inside the state
  # directory, never to the shared port log the support bundle collects.
  : >"$STATE/google-signin.log"
  chmod 600 "$STATE/google-signin.log"
  LD_PRELOAD="${MCPE_GUI_PRELOAD:-}" \
    "$UI" "$QML" "$CAPTURE" >/dev/null 2>"$STATE/google-signin.log" &
fi
ui_pid=$!

wait "$ui_pid"
ui_rc=$?

if [ "$ui_rc" -ne 0 ] || [ ! -s "$CAPTURE" ]; then
  echo "Google sign-in was cancelled or did not finish." >&2
  exit 1
fi
if ! python3 "$SCRIPT_DIR/credentials.py" write-access-input \
       "$CAPTURE" "$AUTH_INPUT"; then
  exit 1
fi
rm -f "$CAPTURE"
: >"$GUI_RESULT"
chmod 600 "$GUI_RESULT"
exit 0
