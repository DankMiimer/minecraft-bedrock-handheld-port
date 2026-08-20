#!/bin/bash
# Build mcbedrock-get as a single-file x86_64 AppImage.
#
# The point is that a Linux user downloads one file, marks it executable and
# runs it -- no distribution packages, no Python version to match, no Tk to
# install. Ubuntu, for one, ships no python3-tk by default, so relying on the
# system Python would fail on a stock install.
#
# Everything the program needs is bundled:
#   * CPython, from niess/python-appimage, which includes tkinter
#   * gpsoauth and pywebview -- both pure Python
#
# The sign-in window is NOT bundled. It is WebKitGTK, driven through PyGObject,
# and PyGObject is compiled against the system interpreter: a bundled Python of
# a different version cannot import it however it is packaged. Bundling Qt
# instead would work, but measured at 525 MB against 58 MB for everything else
# here -- half a gigabyte to draw one login page. So sign-in runs as a child
# process on the SYSTEM python3, importing the pure-Python parts from this
# bundle, and setup-downloader.sh installs the GTK packages alongside the
# compiler it already installs.
#
# gplaydl is NOT bundled. It is built on the user's machine from its own
# source, by setup-downloader.sh, exactly as on Windows -- shipping someone
# else's GPL binary would mean shipping its corresponding source too.
#
# Usage:  bash build-appimage.sh [output-directory]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/dist}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PYTHON_TAG="python3.11"
PYTHON_ASSET="python3.11.16-cp311-cp311-manylinux2014_x86_64.AppImage"
PYTHON_URL="https://github.com/niess/python-appimage/releases/download/${PYTHON_TAG}/${PYTHON_ASSET}"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

VERSION="$(cat "$HERE/VERSION" 2>/dev/null || cat "$HERE/../../VERSION")"
VERSION="${VERSION%$'\n'}"

say() { printf '\n==> %s\n' "$1"; }

say "Fetching the Python base ($PYTHON_ASSET)"
cd "$WORK"
curl -fsSL -o python.AppImage "$PYTHON_URL"
chmod +x python.AppImage
# --appimage-extract avoids needing FUSE, which CI runners do not have.
./python.AppImage --appimage-extract >/dev/null
APPDIR="$WORK/squashfs-root"

say "Installing the Python dependencies into the bundle"
"$APPDIR/AppRun" -m pip install --no-cache-dir --quiet \
    -r "$HERE/requirements-linux.txt"

say "Adding mcbedrock-get"
install -d "$APPDIR/opt/mcbedrock-get"
for module in mcbedrock_get.py catalog.py signin.py linux_backend.py wsl_backend.py \
              apkset.py paths.py setup-downloader.sh; do
    install -m 644 "$HERE/$module" "$APPDIR/opt/mcbedrock-get/$module"
done
chmod 755 "$APPDIR/opt/mcbedrock-get/setup-downloader.sh"

# The base image ships its own launcher, desktop entry and icon for "python".
# Replace them so the AppImage presents itself as this program.
rm -f "$APPDIR"/*.desktop "$APPDIR"/*.png "$APPDIR"/usr/share/applications/*.desktop
cat > "$APPDIR/mcbedrock-get.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Minecraft Bedrock APK downloader
Comment=Download your own Google Play copy of Minecraft Bedrock
Exec=mcbedrock-get
Icon=mcbedrock-get
Categories=Game;Utility;
Terminal=false
DESKTOP
install -Dm644 "$APPDIR/mcbedrock-get.desktop" \
    "$APPDIR/usr/share/applications/mcbedrock-get.desktop"

say "Drawing the icon"
"$APPDIR/AppRun" - "$APPDIR/mcbedrock-get.png" <<'PYICON'
import struct, sys, zlib

# A grass block, the same one the window draws, written as a PNG without
# needing an image library in the build environment.
SIZE = 256
GRASS_TOP, GRASS_SIDE, SOIL_A, SOIL_B = (
    (0x7c, 0xc7, 0x5c), (0x5d, 0x9c, 0x40), (0x8a, 0x5a, 0x3b), (0x75, 0x49, 0x2f),
)
rows = []
for y in range(SIZE):
    row = bytearray(b"\x00")
    for x in range(SIZE):
        if y < SIZE * 0.28:
            colour = GRASS_TOP
        elif y < SIZE * 0.38:
            colour = GRASS_SIDE
        else:
            colour = SOIL_A if (x // 32 + y // 32) % 2 else SOIL_B
        row += bytes(colour)
    rows.append(bytes(row))

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PYICON
install -Dm644 "$APPDIR/mcbedrock-get.png" \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps/mcbedrock-get.png"

say "Writing the launcher"
# The base image ships AppRun as a SYMLINK to the bundled interpreter. Writing
# to it without removing it first follows the link and overwrites python itself,
# leaving an AppImage whose "interpreter" is this shell script.
rm -f "$APPDIR/AppRun"
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
# Runs the bundled interpreter against the bundled program. -s and -E keep a
# user's own PYTHONPATH or site-packages from being mixed into the bundle,
# which is the usual way a self-contained build stops being self-contained.
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export TCL_LIBRARY="$HERE/usr/share/tcltk/tcl8.6"
export TK_LIBRARY="$HERE/usr/share/tcltk/tk8.6"
export TKPATH="$TK_LIBRARY"
# Sign-in runs on the system python3, which needs to import the pure-Python
# packages shipped in here (pywebview, gpsoauth) while using the system's own
# compiled PyGObject.
export MCBEDROCK_PURE_PYTHON="$(echo "$HERE"/opt/python*/lib/python*/site-packages)"

# A bundled Python carries no CA store, and looks for one where the machine it
# was built on kept it. Without this every HTTPS call fails, which shows up as
# the version list silently falling back to the handful of builds compiled in.
if [ -z "${SSL_CERT_FILE:-}" ]; then
    for bundle in /etc/ssl/certs/ca-certificates.crt                   /etc/pki/tls/certs/ca-bundle.crt                   /etc/ssl/ca-bundle.pem                   "$MCBEDROCK_PURE_PYTHON/certifi/cacert.pem"; do
        [ -r "$bundle" ] && export SSL_CERT_FILE="$bundle" && break
    done
fi
# The interpreter lives under opt/; usr/bin holds symlinks whose relative
# targets do not survive being re-rooted into a different AppDir.
for candidate in "$HERE"/opt/python*/bin/python3.*; do
    case "$candidate" in *-config|*-config3) continue ;; esac
    [ -x "$candidate" ] && PYTHON="$candidate" && break
done
if [ -z "${PYTHON:-}" ]; then
    echo "mcbedrock-get: no bundled interpreter found in $HERE/opt" >&2
    exit 1
fi
exec "$PYTHON" -s -E "$HERE/opt/mcbedrock-get/mcbedrock_get.py" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

say "Packing the AppImage"
mkdir -p "$WORK/tool"
curl -fsSL -o "$WORK/tool/appimagetool" "$APPIMAGETOOL_URL"
chmod +x "$WORK/tool/appimagetool"
# Extract in its own directory: appimagetool unpacks to "squashfs-root" as
# well, which is the AppDir's name, and doing both in one place destroys it.
(cd "$WORK/tool" && ./appimagetool --appimage-extract >/dev/null)
mkdir -p "$OUT"
TARGET="$OUT/mcbedrock-get-linux-x86_64-v${VERSION}.AppImage"
# ARCH is required when appimagetool cannot infer it from the AppDir.
ARCH=x86_64 "$WORK/tool/squashfs-root/AppRun" "$APPDIR" "$TARGET" >/dev/null

say "Built $TARGET"
ls -lh "$TARGET" | awk '{print "    " $5}'
sha256sum "$TARGET" | awk '{print "    sha256 " $1}'
