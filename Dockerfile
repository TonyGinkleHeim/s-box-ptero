# s&box Dedicated Server image for Pterodactyl
# Base: Debian 12 (bookworm) — has the glibc/libssl/libicu versions Source 2 + .NET 8 expect.
FROM        --platform=$TARGETOS/$TARGETARCH debian:bookworm-slim

LABEL       author="generated" maintainer="ops@local"

ENV         DEBIAN_FRONTEND=noninteractive

RUN         dpkg --add-architecture i386 \
            && apt-get update \
            && apt-get install -y --no-install-recommends \
                ca-certificates \
                curl \
                wget \
                gnupg \
                lib32gcc-s1 \
                lib32stdc++6 \
                libgcc-s1 \
                libstdc++6 \
                libcurl4 \
                libicu72 \
                libssl3 \
                libsdl2-2.0-0 \
                libgl1 \
                libglib2.0-0 \
                libtinfo6 \
                locales \
                tar \
                xz-utils \
                tzdata \
                iproute2 \
                netbase \
                file \
            && rm -rf /var/lib/apt/lists/*

# .NET 8 runtime (sbox-server.exe is a managed .NET 8 binary)
RUN         wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/ms.deb \
            && dpkg -i /tmp/ms.deb \
            && rm /tmp/ms.deb \
            && apt-get update \
            && apt-get install -y --no-install-recommends dotnet-runtime-8.0 aspnetcore-runtime-8.0 \
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
