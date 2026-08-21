# Debian image and apt repository snapshot are both immutable inputs.
FROM debian:bookworm-20260713@sha256:41a613df4beca480a97c22b1f6837f7502cb95206e2cc2daf1ea3cb28f8755ab AS build
ENV DEBIAN_FRONTEND=noninteractive SOURCE_DATE_EPOCH=1783900800
RUN rm -f /etc/apt/sources.list.d/debian.sources && printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260713T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260713T000000Z bookworm-security main' \
      > /etc/apt/sources.list && \
    dpkg --add-architecture arm64 && dpkg --add-architecture armhf && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends \
      ca-certificates clang cmake file git lld make patch pkg-config protobuf-compiler python3 \
      libwayland-bin wayland-protocols \
      binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf \
      g++-aarch64-linux-gnu g++-arm-linux-gnueabihf \
      libssl-dev:arm64 libpng-dev:arm64 zlib1g-dev:arm64 libx11-dev:arm64 \
      libxext-dev:arm64 libxi-dev:arm64 libxcursor-dev:arm64 libxrandr-dev:arm64 \
      libxinerama-dev:arm64 libegl1-mesa-dev:arm64 libgles2-mesa-dev:arm64 \
      libudev-dev:arm64 libevdev-dev:arm64 libuv1-dev:arm64 libzip-dev:arm64 \
      libprotobuf-dev:arm64 libopenal-dev:arm64 libpulse-dev:arm64 libasound2-dev:arm64 \
      libssl-dev:armhf libpng-dev:armhf zlib1g-dev:armhf libx11-dev:armhf \
      libxext-dev:armhf libxi-dev:armhf libxcursor-dev:armhf libxrandr-dev:armhf \
      libxinerama-dev:armhf libegl1-mesa-dev:armhf libgles2-mesa-dev:armhf \
      libudev-dev:armhf libevdev-dev:armhf libuv1-dev:armhf libzip-dev:armhf \
      libprotobuf-dev:armhf libopenal-dev:armhf libpulse-dev:armhf libasound2-dev:armhf \
      libwayland-dev:armhf libxkbcommon-dev:armhf libdrm-dev:armhf libgbm-dev:armhf && \
    rm -rf /var/lib/apt/lists/*
ARG TARGET_ARCH
ARG EDITION
COPY source_release /patches
COPY bottomscreen/telemetry /telemetry
COPY build/clients/build-in-container.sh /usr/local/bin/build-client
RUN chmod 0755 /usr/local/bin/build-client && build-client "$TARGET_ARCH" "$EDITION"

FROM scratch AS export
COPY --from=build /out/ /
