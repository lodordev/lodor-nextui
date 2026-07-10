#!/bin/sh
# assemble.sh — stage Lodor-NextUI for a stock-NextUI SD card as ONE self-onboarding Tool pak per
# device:
#   Tools/{tg5040,tg5050}/Lodor.pak   — the sync layer (engine + hooks + Tools menu) AND the
#                                       on-device onboarding/pairing wizard, merged into one pak. On
#                                       first open (no config.json/token yet) it runs the wizard
#                                       (server URL -> pairing code -> device name via minui-keyboard);
#                                       once configured it runs the normal client, with a
#                                       "Setup / Re-pair" menu entry to re-run the wizard. (The former
#                                       separate "Lodor Setup.pak" is GONE — one Tools-menu entry.)
#
# Builds the engine from the CURRENT monorepo HEAD (golang:1.25, CGO-free, arm64 — one binary serves
# both tg5040 and tg5050) and lays down the pak source from THIS directory. Third-party host-render
# binaries (minui-list / minui-presenter / minui-keyboard), 7zz, and the CA bundle are NOT committed
# here; point the vars below at a source that has them (a prior stage / the stock Wifi.pak /
# josegonzalez minui-* releases). Heavy emu paks are intentionally out of scope (card-side / private).
#
# Usage:  ASSETS=<dir-with-bin/7zz+bin/tg5040/minui-*>  CERT=<ca-certificates.crt>  ./assemble.sh [outdir]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# OPTIONAL GATE (recommended before any card stage): off-device wizard/menu simulation + static
# lint of the whole pak shell surface — catches interaction-loop traps without a hardware boot.
# "$HERE/test/check.sh" || exit 1
PAKSRC="$HERE/Lodor.pak"
MONO="$(cd "$HERE/../.." && pwd)"          # integrations/nextui -> repo root
OUT="${1:-/tmp/lodor-nextui-ship}"
ASSETS="${ASSETS:-/mnt/cache/tmp/lodor-nextui-stage/Tools/tg5040/Lodor.pak}"
CERT="${CERT:-$MONO/lodoros/paks/Lodor.pak/certs/ca-certificates.crt}"
TSBIN="${TSBIN:-/mnt/cache/tmp/ts-stage/official-1.94.1}"   # static aarch64 tailscaled + tailscale (official v1.94.1)
TCIMG="${TCIMG:-tg5040-toolchain:latest}"                    # NextUI aarch64 toolchain (SDL2) — builds lodor-qr
QRSRC="$HERE/qr-helper"                                       # standalone SDL QR helper source (qrcodegen + embedded font)

echo "== building arm64 engine from $(cd "$MONO" && git rev-parse --short HEAD) =="
ENG="$MONO/engine/.build-nextui-arm64-$(cd "$MONO" && git rev-parse --short HEAD)"
docker run --rm -v "$MONO/engine":/src -w /src \
  -e GOCACHE=/tmp/gc -e GOPATH=/tmp/gp -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm64 \
  golang:1.25 go build -trimpath -ldflags="-s -w -X lodor/buildinfo.Version=$(cat "$MONO/VERSION")" -o "/src/$(basename "$ENG")" ./cmd/lodor-sync
file "$ENG" | grep -q aarch64 || { echo "FATAL: engine is not arm64"; exit 1; }

echo "== building aarch64 QR helper (lodor-qr) in $TCIMG =="
QRBIN_OUT="$QRSRC/lodor-qr"
docker run --rm -v "$QRSRC":/src -w /src "$TCIMG" sh -c '
  . /root/setup-env.sh
  SR=/opt/aarch64-linux-gnu/aarch64-linux-gnu/libc/usr
  ${CROSS_COMPILE}gcc -O2 -mcpu=cortex-a53 -Wall -I$SR/include -I$SR/include/SDL2 \
    lodor-qr.c qrcodegen.c -o lodor-qr \
    -L$SR/lib -lSDL2 -lSDL2_ttf -lpthread -ldl -lm'
file "$QRBIN_OUT" | grep -q aarch64 || { echo "FATAL: lodor-qr is not arm64"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
for PLAT in tg5040 tg5050; do
  # ---- Lodor.pak (self-onboarding sync layer) ----
  D="$OUT/Tools/$PLAT/Lodor.pak"
  mkdir -p "$D/bin/$PLAT" "$D/lib" "$D/hooks" "$D/certs"
  cp "$PAKSRC/launch.sh" "$D/launch.sh"
  cp -r "$PAKSRC/lib/." "$D/lib/"
  cp -r "$PAKSRC/hooks/." "$D/hooks/"
  cp -r "$PAKSRC/gmpak" "$D/gmpak"   # Game Manager root-entry sources (launch.sh self-heals from these)
  cp -r "$PAKSRC/ctpak" "$D/ctpak"   # Continue root-entry sources (task #134, same self-heal pattern)
  cp "$PAKSRC/bin/romm-run" "$D/bin/romm-run"
  cp "$PAKSRC/bin/romm-syncd" "$D/bin/romm-syncd"
  cp "$PAKSRC/bin/post-uninstall.sh" "$D/bin/post-uninstall.sh"   # store post_uninstall hook (#30)
  cp "$PAKSRC/pak.json" "$D/pak.json"
  cp "$PAKSRC/config.json.template" "$D/config.json.template"
  cp "$ENG" "$D/lodor-sync"
  cp "$CERT" "$D/certs/ca-certificates.crt"
  # Handoff manifests (#27) — LIGHTS statesync on NextUI. Both tg5040/tg5050 are arm64.
  # dir = minarch {TAG}-{core} under .userdata/shared/ (verified off NextUI source:
  # ma_core.c states_dir = SHARED_USERDATA/<tag>-<corename>; note SFC not SNES). Keys =
  # RomM fs_slug verified live (genesis, NOT megadrive; mastersystem, NOT sms). NextUI
  # runs snes9x (full) for SNES — matches Knulli/Android/muOS(post-#11) arm64 snes9x
  # club, not the Miyoo armhf snes9x2005_plus (SNES is within-bitness-group by design).
  #   GBA=gpsp matches LodorOS; muOS/Knulli/Android run mgba → cross-lane orphan, flagged
  #   fleet-wide. GG/SMS/MD=picodrive matches LodorOS-my355/Knulli; muOS runs
  #   genesis_plus_gx → that arm64 split is muOS-#11's flag.
  #   PSX/N64 (#14/#5/#6): NOT emitted for NextUI. NextUI's PSX (pcsx_rearmed) and N64
  #   (mupen64plus_next) core assignment through the state-producing minarch path is NOT
  #   confirmed from source — declaring them unverified would fake a capability. Left out
  #   honestly and FLAGGED for on-device confirmation (see flagged-cells list); add here
  #   iff a tg5040/tg5050 check shows those systems run those libretro cores via minarch.
  sh "$MONO/release/mkstatecores.sh" --frontend nextui --arch arm64 --out "$D/statecores.json" \
    nes=fceumm:FC-fceumm gb=gambatte:GB-gambatte gbc=gambatte:GBC-gambatte \
    gba=gpsp:GBA-gpsp gamegear=picodrive:GG-picodrive \
    mastersystem=picodrive:SMS-picodrive genesis=picodrive:MD-picodrive \
    snes=snes9x:SFC-snes9x >&2 || { echo "nextui statecores emit failed" >&2; exit 1; }
  # D8 whitelist (fix #2 — the fleet-UNIFORM class list; identical on every lane).
  sh "$MONO/release/mkstatecompat.sh" --out "$D/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:arm64 genesis_plus_gx:arm64 >&2 \
    || { echo "nextui statecompat emit failed" >&2; exit 1; }
  cp "$ASSETS/bin/7zz" "$D/bin/7zz"
  # arm64 host-render tools. The MERGED pak now needs minui-keyboard too (onboarding text entry) —
  # it used to live only in the deleted Lodor Setup.pak. tg5050 reuses the tg5040 build (same arm64 +
  # /usr/trimui/lib NextUI userland) — VERIFY on tg5050 hardware before trusting it.
  cp "$ASSETS/bin/tg5040/minui-list" "$D/bin/$PLAT/minui-list"
  cp "$ASSETS/bin/tg5040/minui-presenter" "$D/bin/$PLAT/minui-presenter"
  cp "$ASSETS/bin/tg5040/minui-keyboard" "$D/bin/$PLAT/minui-keyboard"
  # Tailscale (tier-1 QR sign-in): static aarch64 daemon + CLI — ONE copy (both devices arm64).
  mkdir -p "$D/bin/tailscale"
  cp "$TSBIN/tailscaled" "$D/bin/tailscale/tailscaled"
  cp "$TSBIN/tailscale"  "$D/bin/tailscale/tailscale"
  # standalone SDL QR helper (host rendering only; drawn in-pak, no NextUI fork).
  cp "$QRBIN_OUT" "$D/bin/$PLAT/lodor-qr"
  chmod +x "$D/launch.sh" "$D/lodor-sync" "$D/bin/romm-run" "$D/bin/romm-syncd" "$D/bin/post-uninstall.sh" \
           "$D/bin/7zz" "$D/bin/$PLAT/minui-list" "$D/bin/$PLAT/minui-presenter" \
           "$D/bin/$PLAT/minui-keyboard" "$D/bin/tailscale/tailscaled" \
           "$D/bin/tailscale/tailscale" "$D/bin/$PLAT/lodor-qr"
  find "$D/hooks" -name '*.sh' -exec chmod +x {} +
  chmod +x "$D/gmpak/launch.sh" "$D/ctpak/launch.sh"

  # ---- Game Manager ROOT ENTRY (task #128; bottom-sorted task #134) — ships ON THE CARD ----
  # Roms/"Game Manager (LODORGM)" renders at the BOTTOM of NextUI's library via the on-device
  # Roms/map.txt NBSP alias (written by the boot/pak heal — deliberately NOT shipped in this
  # stage: map.txt on a user's card must be MERGED, never clobbered by an unzip); the
  # <dirname>.m3u makes it a ONE-PRESS auto-launch dir; Emus/<plat>/LODORGM.pak is the
  # "emulator" that execs Tools/<plat>/Lodor.pak/launch.sh --game-manager. Zero NextUI fork.
  E="$OUT/Emus/$PLAT/LODORGM.pak"
  mkdir -p "$E"
  cp "$PAKSRC/gmpak/launch.sh" "$E/launch.sh"
  chmod +x "$E/launch.sh"

  # ---- Continue ROOT ENTRY (task #134): the one-press cross-device resume row. "0) " digit
  # prefix sorts it FIRST (trimSortingMeta renders "Continue"; the engine may alias it to
  # "0) Continue: <Game>" via the on-device map.txt); LODORCT.pak is the resume DISPATCHER
  # (fetch bracket -> real emulator -> push bracket). Zero NextUI fork.
  C="$OUT/Emus/$PLAT/LODORCT.pak"
  mkdir -p "$C"
  cp "$PAKSRC/ctpak/launch.sh" "$C/launch.sh"
  chmod +x "$C/launch.sh"
done

# One shared Roms folder serves both platforms (same SD card layout).
R="$OUT/Roms/Game Manager (LODORGM)"
mkdir -p "$R"
cp "$PAKSRC/gmpak/roms/Open Game Manager.gm" "$R/Open Game Manager.gm"
cp "$PAKSRC/gmpak/roms/Game Manager (LODORGM).m3u" "$R/Game Manager (LODORGM).m3u"
R="$OUT/Roms/0) Continue (LODORCT)"
mkdir -p "$R"
cp "$PAKSRC/ctpak/roms/Continue.ct" "$R/Continue.ct"
cp "$PAKSRC/ctpak/roms/0) Continue (LODORCT).m3u" "$R/0) Continue (LODORCT).m3u"
echo "== staged at $OUT =="
find "$OUT" -type f | sed "s#$OUT/##" | sort
