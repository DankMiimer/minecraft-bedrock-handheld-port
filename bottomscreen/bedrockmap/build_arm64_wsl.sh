#!/usr/bin/env bash
# Cross-compile bedrockmap (static leveldb-mcpe) for the RG DS.
# Uses a SEPARATE leveldb tree copy so the PC shared-lib build at
# /root/bedrockmap/leveldb-mcpe stays intact.
set -e
SRC=/mnt/c/Programmering/SBC/RG34xxSP/Minecraft_Bedrock_PortMaster/bottomscreen
LDB=/root/bedrockmap/leveldb-mcpe
LDB64=/root/bedrockmap/leveldb-arm64

if [ ! -d "$LDB64" ]; then
  cp -r "$LDB" "$LDB64"
  rm -rf "$LDB64/build"
  sed -i 's/add_library(leveldb_mcpe SHARED)/add_library(leveldb_mcpe STATIC)/' \
      "$LDB64/CMakeLists.txt"
fi

docker run --rm \
  -v /root/bedrockmap:/w \
  -v "$SRC":/bs:ro \
  mcpe-build:bookworm bash -c '
set -e
cd /w/leveldb-arm64
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_FLAGS=--target=aarch64-linux-gnu \
  -DCMAKE_CXX_FLAGS=--target=aarch64-linux-gnu \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DZLIB_LIBRARY=/usr/lib/aarch64-linux-gnu/libz.so \
  -DZLIB_INCLUDE_DIR=/usr/include \
  > /dev/null
make -C build -j8 leveldb_mcpe 2>&1 | tail -1
clang++ --target=aarch64-linux-gnu -O2 -std=c++17 -DDLLX= \
  -o /w/bedrockmap.arm64 /bs/bedrockmap/bedrockmap.cpp \
  -I/w/leveldb-arm64/include \
  /w/leveldb-arm64/build/libleveldb_mcpe.a \
  -lz -lrt -lpthread
file /w/bedrockmap.arm64'
echo "built /root/bedrockmap/bedrockmap.arm64"
