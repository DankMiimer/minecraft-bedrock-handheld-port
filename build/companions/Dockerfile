FROM debian:bookworm-20260713@sha256:41a613df4beca480a97c22b1f6837f7502cb95206e2cc2daf1ea3cb28f8755ab AS build
ENV DEBIAN_FRONTEND=noninteractive SOURCE_DATE_EPOCH=1783900800
RUN rm -f /etc/apt/sources.list.d/debian.sources && printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260713T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260713T000000Z bookworm-security main' \
      > /etc/apt/sources.list && \
    dpkg --add-architecture arm64 && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends \
      ca-certificates cmake file git make libwayland-bin wayland-protocols \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
      libwayland-dev:arm64 libpng-dev:arm64 zlib1g-dev:arm64 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY source_release source_release
COPY bottomscreen/bottomd bottomscreen/bottomd
COPY bottomscreen/telemetry bottomscreen/telemetry
COPY bottomscreen/bedrockmap bottomscreen/bedrockmap
COPY scripts/build_context_bridge.sh scripts/build_context_bridge.sh
COPY scripts/build_rgds_artifacts.sh scripts/build_rgds_artifacts.sh
RUN chmod 0755 scripts/*.sh && \
    scripts/build_context_bridge.sh /out/crusty-context-v1.so && \
    scripts/build_rgds_artifacts.sh /out

FROM scratch AS export
COPY --from=build /out/ /
