#!/bin/sh
# build.sh — cross-compile the standalone lodor-qr SDL helper for aarch64 (tg5040 / tg5050).
#
# Uses the SAME toolchain NextUI's own paks/launcher are built with (the tg5040-toolchain
# image, aarch64 gcc + SDL2 + SDL2_ttf sysroot). The output is dynamically linked against
# libSDL2 / libSDL2_ttf, which the device already ships in /usr/trimui/lib (a strict subset
# of what the bundled minui-presenter needs). assemble.sh runs this same recipe; this script
# is for standalone rebuilds / provenance.
#
# Usage:  ./build.sh   (or  TCIMG=tg5040-toolchain:latest ./build.sh)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
TCIMG="${TCIMG:-tg5040-toolchain:latest}"
docker run --rm -v "$HERE":/src -w /src "$TCIMG" sh -c '
  . /root/setup-env.sh
  SR=/opt/aarch64-linux-gnu/aarch64-linux-gnu/libc/usr
  ${CROSS_COMPILE}gcc -O2 -mcpu=cortex-a53 -Wall -I$SR/include -I$SR/include/SDL2 \
    lodor-qr.c qrcodegen.c -o lodor-qr \
    -L$SR/lib -lSDL2 -lSDL2_ttf -lpthread -ldl -lm'
file "$HERE/lodor-qr" | grep -q aarch64 || { echo "FATAL: lodor-qr is not aarch64"; exit 1; }
echo "built: $HERE/lodor-qr"
