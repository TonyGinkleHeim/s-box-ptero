# s&box Dedicated Server image for Pterodactyl
# Base: Debian 13 (trixie) — engine2 needs glibc 2.38+ and GLIBCXX_3.4.31+. Bookworm ships glibc 2.36.
FROM        --platform=$TARGETOS/$TARGETARCH debian:trixie-slim

LABEL       org.opencontainers.image.source="https://github.com/TonyGinkleHeim/sbox-pterodactyl"
LABEL       org.opencontainers.image.description="s&box Pterodactyl egg runtime (.NET 8 native)"

ENV         DEBIAN_FRONTEND=noninteractive

RUN         apt-get update \
            && apt-get install -y --no-install-recommends \
                ca-certificates \
                curl \
                wget \
                gnupg \
                libgcc-s1 \
                libstdc++6 \
                libcurl4 \
                libicu76 \
                libssl3 \
                libsdl2-2.0-0 \
                libgl1 \
                libglib2.0-0 \
                libtinfo6 \
                libvulkan1 \
                libxcb1 \
                libx11-6 \
                libxext6 \
                libxrandr2 \
                libxinerama1 \
                libxi6 \
                libxcursor1 \
                libxss1 \
                libfontconfig1 \
                libfreetype6 \
                libpulse0 \
                libasound2 \
                libudev1 \
                libusb-1.0-0 \
                libpci3 \
                zlib1g \
                libatomic1 \
                libnss3 \
                libnspr4 \
                locales \
                tar \
                xz-utils \
                tzdata \
                iproute2 \
                netbase \
                file \
                binutils \
            && rm -rf /var/lib/apt/lists/*

RUN         wget -q https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb -O /tmp/ms.deb \
            && dpkg -i /tmp/ms.deb \
            && rm /tmp/ms.deb \
            && apt-get update \
            && apt-get install -y --no-install-recommends dotnet-runtime-10.0 aspnetcore-runtime-10.0 \
            && rm -rf /var/lib/apt/lists/*

RUN         locale-gen en_US.UTF-8
ENV         LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

RUN         useradd -m -d /home/container -s /bin/bash container
USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL  SIGINT

COPY        --chown=container:container ./entrypoint.sh /entrypoint.sh
CMD         [ "/bin/bash", "/entrypoint.sh" ]
