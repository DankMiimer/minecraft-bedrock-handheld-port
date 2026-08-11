#!/bin/bash
# One-time setup: build the Google Play downloader inside WSL.
#
# This builds gplaydl from minecraft-linux/google-play-api, the only Play client
# still able to download Minecraft. Nothing here touches the game itself.
#
# Run inside Ubuntu:
#     bash wsl-setup.sh

SRC="$HOME/gplaydl-src"
PREFIX="$HOME/.local/share/mcbedrock-get"

# Never let the window vanish with an error scrolled off screen.
pause_and_exit() {
    echo
    echo "$1"
    echo
    read -r -p "Press Enter to close this window. " _
    exit "$2"
}

fail() { pause_and_exit "SETUP FAILED: $1" 1; }

echo "==> Installing build dependencies"
echo "    sudo will ask for your Ubuntu password."
echo

# 'apt-get update' is allowed to fail. A broken third-party repository must not
# stop the install, and the packages below come from Ubuntu's own archive, which
# is already indexed.
sudo apt-get update || echo "(apt-get update reported a problem - continuing)"

sudo apt-get install -y --no-install-recommends \
    build-essential cmake git \
    protobuf-compiler libprotobuf-dev \
    libcurl4-openssl-dev zlib1g-dev \
    || fail "could not install the build dependencies (see the errors above)"

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

pause_and_exit "Setup finished. Close this window and press Download again." 0
