FROM debian:bookworm

RUN dpkg --add-architecture arm64 \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      g++-aarch64-linux-gnu \
      qt6-base-dev-tools \
      qt6-base-dev:arm64 \
      qt6-declarative-dev:arm64 \
      qt6-webengine-dev:arm64 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY main.cpp /work/main.cpp

RUN /usr/lib/qt6/libexec/moc /work/main.cpp -o /work/main.moc \
 && aarch64-linux-gnu-g++ -std=c++17 -O2 -fPIC -pie \
      -I/work \
      -I/usr/include/aarch64-linux-gnu/qt6 \
      -I/usr/include/aarch64-linux-gnu/qt6/QtCore \
      -I/usr/include/aarch64-linux-gnu/qt6/QtGui \
      -I/usr/include/aarch64-linux-gnu/qt6/QtNetwork \
      -I/usr/include/aarch64-linux-gnu/qt6/QtQml \
      -I/usr/include/aarch64-linux-gnu/qt6/QtWebEngineCore \
      -I/usr/include/aarch64-linux-gnu/qt6/QtWebEngineQuick \
      /work/main.cpp -o /work/mcpe-signin \
      -L/usr/lib/aarch64-linux-gnu \
      -lQt6WebEngineQuick -lQt6WebEngineCore -lQt6Quick -lQt6Qml \
      -lQt6Network -lQt6Gui -lQt6Core \
 && aarch64-linux-gnu-strip /work/mcpe-signin
