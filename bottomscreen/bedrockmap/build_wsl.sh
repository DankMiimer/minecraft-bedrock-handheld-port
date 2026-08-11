#!/usr/bin/env bash
# Build bedrockmap on WSL (PC-native test build).
# Prereqs (already done once, 2026-07-10, WSL as root):
#   apt-get install -y zlib1g-dev
#   git clone --depth 1 https://github.com/Amulet-Team/leveldb-mcpe \
#       /root/bedrockmap/leveldb-mcpe
#   # its CMakeLists links `zlibstatic`, which doesn't exist when using
#   # system zlib — replace with ZLIB::ZLIB:
#   sed -i 's/PRIVATE zlibstatic/PRIVATE ZLIB::ZLIB/' CMakeLists.txt
#   cmake -B build -DCMAKE_BUILD_TYPE=Release && make -C build -j8
#
# Device builds (aarch64/armhf): do the same inside mcpe-build:bookworm
# with the cross toolchain; prefer -DBUILD_SHARED_LIBS=OFF for a static
# libleveldb (TODO when Phase-3 device integration starts).
set -e
LDB=/root/bedrockmap/leveldb-mcpe
SRC="$(cd "$(dirname "$0")" && pwd)"
# -DDLLX=: the headers wrap classes in a Windows export macro that the
# library defines internally; consumers must define it empty.
g++ -O2 -std=c++17 -Wall -Wextra -DDLLX= -o /root/bedrockmap/bedrockmap \
    "$SRC/bedrockmap.cpp" \
    -I"$LDB/include" \
    "$LDB/build/libleveldb_mcpe.so" \
    -Wl,-rpath,"$LDB/build" -lz -lpthread
cp "$SRC/block_colors.tsv" /root/bedrockmap/
echo "built /root/bedrockmap/bedrockmap"
