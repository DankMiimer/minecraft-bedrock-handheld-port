#!/bin/bash
# One-time setup: build the Google Play downloader inside WSL.
#
# This builds gplaydl from minecraft-linux/google-play-api, the only Play client
# still able to download Minecraft. Nothing here touches the game itself.
#
# The helper pipes this in as root and reads the output itself, so there is no
# terminal, no password prompt and nothing to press. It still runs by hand:
#     bash setup-downloader.sh

SRC="$HOME/gplaydl-src"
PREFIX="$HOME/.local/share/mcbedrock-get"


# Only installing packages needs root. The BUILD must not: it installs into
# $HOME, and running the whole script as root would put gplaydl in root's home,
# where the helper -- running as your own user on Linux -- would never find it.
#
# Under WSL the helper already drives this as root, so run_root just runs the
# command. On a Linux desktop there is no terminal to type a sudo password
# into, so pkexec asks graphically; sudo is the fallback for a real terminal.
run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif [ -z "${MCBEDROCK_NO_PKEXEC:-}" ] && command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    else
        sudo "$@"
    fi
}

# Never let a terminal window vanish with an error scrolled off screen -- but
# never block the helper, which has no keyboard to offer.
pause_and_exit() {
    echo
    echo "$1"
    echo
    if [ -t 0 ] && [ -z "${MCBEDROCK_NONINTERACTIVE:-}" ]; then
        read -r -p "Press Enter to close this window. " _
    fi
    exit "$2"
}

fail() { pause_and_exit "SETUP FAILED: $1" 1; }

echo "==> Installing build dependencies"
[ "$(id -u)" -eq 0 ] || echo "    You will be asked to authorise this once."
echo

export DEBIAN_FRONTEND=noninteractive

# Packages that draw Google's sign-in page. Only wanted when this is a real
# Linux desktop: under WSL the sign-in window is Edge on the Windows side, and
# pulling GTK into the distribution would be megabytes for nothing.
SIGNIN_APT="python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 gir1.2-soup-3.0"
SIGNIN_DNF="python3-gobject gtk3 webkit2gtk4.1 libsoup3"
SIGNIN_PACMAN="python-gobject gtk3 webkit2gtk-4.1 libsoup3"
if [ -n "${MCBEDROCK_NO_SIGNIN_DEPS:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    SIGNIN_APT=""; SIGNIN_DNF=""; SIGNIN_PACMAN=""
    echo "    (WSL detected: skipping the Linux sign-in packages)"
fi

if command -v apt-get >/dev/null 2>&1; then
    # 'update' is allowed to fail: a broken third-party repository must not stop
    # the install, and these packages come from the distribution's own archive,
    # which is already indexed.
    run_root apt-get update || echo "(apt-get update reported a problem - continuing)"
    # shellcheck disable=SC2086  # the package list is intentionally split
    run_root apt-get install -y --no-install-recommends \
        build-essential cmake git \
        protobuf-compiler libprotobuf-dev \
        libcurl4-openssl-dev zlib1g-dev $SIGNIN_APT \
        || fail "could not install the build dependencies (see the errors above)"
elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    run_root dnf install -y \
        gcc-c++ make cmake git \
        protobuf-compiler protobuf-devel \
        libcurl-devel zlib-devel $SIGNIN_DNF \
        || fail "could not install the build dependencies (see the errors above)"
elif command -v pacman >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    run_root pacman -S --needed --noconfirm \
        base-devel cmake git protobuf curl zlib $SIGNIN_PACMAN \
        || fail "could not install the build dependencies (see the errors above)"
else
    fail "no supported package manager found (looked for apt-get, dnf and pacman)."
fi

command -v protoc >/dev/null || fail "protoc is still missing after installation"

echo
echo "==> Fetching source"
if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull --ff-only || echo "(could not update the existing checkout - using it as is)"
else
    rm -rf "$SRC"
    git clone --depth 1 https://github.com/minecraft-linux/google-play-api.git "$SRC" \
        || fail "could not download the source"
fi

echo
echo "==> Building (this takes a few minutes)"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
    || fail "cmake could not configure the build"
cmake --build "$SRC/build" --target gplaydl gplayver -j "$(nproc)" \
    || fail "the build did not complete"

echo
echo "==> Installing to $PREFIX"
mkdir -p "$PREFIX" || fail "could not create $PREFIX"
install -m 755 "$SRC/build/gplaydl" "$PREFIX/gplaydl" || fail "gplaydl was not built"
install -m 755 "$SRC/build/gplayver" "$PREFIX/gplayver" || fail "gplayver was not built"

# Only the ABI is overridden. Every other device property keeps the upstream
# default, which is the identity Google currently accepts.
cat > "$PREFIX/device-arm64.conf" <<'EOF'
config.native_platforms = [
    arm64-v8a
]
EOF

cat > "$PREFIX/device-armhf.conf" <<'EOF'
config.native_platforms = [
    armeabi-v7a
]
EOF

pause_and_exit "Setup finished." 0
