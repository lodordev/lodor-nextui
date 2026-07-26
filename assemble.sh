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
EMUSRC="$HERE/emus"                                          # Lodor-NextUI Emu-pak overlays (GBA=mgba fleet flip)
# NextUI-built, ABI-matched mgba_libretro.so (the one NextUI ships in MGBA.pak/SGB.pak via
# CORES+= mgba) — NOT the Lodor mgba-cert binary. Point at a NextUI cores build output or the
# stock EXTRAS MGBA.pak. mGBA is a HARD Lodor dependency (GBA save-state sync is only
# deterministic on mgba); assemble FATALs if this is missing. Defaults to the canonical
# lodor-nextui-stage core. NOT committed to this public repo (build artifact).
MGBACORE="${MGBACORE:-/mnt/cache/tmp/lodor-nextui-stage/Emus/tg5040/MGBA.pak/mgba_libretro.so}"

echo "== building arm64 engine from $(cd "$MONO" && git rev-parse --short HEAD) =="
ENG="$MONO/engine/.build-nextui-arm64-$(cd "$MONO" && git rev-parse --short HEAD)"
docker run --rm -v "$MONO/engine":/src -w /src \
  -e GOCACHE=/tmp/gc -e GOPATH=/tmp/gp -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm64 \
  golang:1.25 go build -trimpath -ldflags="-s -w -X lodor/buildinfo.Version=$(cat "$MONO/VERSION")" -o "/src/$(basename "$ENG")" ./cmd/lodor-sync
file "$ENG" | grep -q aarch64 || { echo "FATAL: engine is not arm64"; exit 1; }

# Launch-card wizard (task launch-card-v2): the SAME build recipe as the lane's lodor-sync —
# golang:1.25, CGO-free, arm64, DEFAULT build tags (no -tags muos: NextUI rides the default
# MinUI-family platform paths + LODOR_HOST_OS=nextui at runtime, exactly like the engine above;
# the muos tag is for the muOS/Knulli apps only). Lands at PAK ROOT next to lodor-sync because
# the wizard resolves the engine as its own sibling (engineBin() in cmd/lodor-wizard/main.go).
echo "== building arm64 launch-card wizard (lodor-wizard) =="
WIZ="$MONO/engine/.build-nextui-wizard-arm64-$(cd "$MONO" && git rev-parse --short HEAD)"
docker run --rm -v "$MONO/engine":/src -w /src \
  -e GOCACHE=/tmp/gc -e GOPATH=/tmp/gp -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm64 \
  golang:1.25 go build -trimpath -ldflags="-s -w -X lodor/buildinfo.Version=$(cat "$MONO/VERSION")" -o "/src/$(basename "$WIZ")" ./cmd/lodor-wizard
file "$WIZ" | grep -q aarch64 || { echo "FATAL: lodor-wizard is not arm64"; exit 1; }

echo "== building aarch64 QR helper (lodor-qr) in $TCIMG =="
QRBIN_OUT="$QRSRC/lodor-qr"
docker run --rm -v "$QRSRC":/src -w /src "$TCIMG" sh -c '
  . /root/setup-env.sh
  SR=/opt/aarch64-linux-gnu/aarch64-linux-gnu/libc/usr
  ${CROSS_COMPILE}gcc -O2 -mcpu=cortex-a53 -Wall -I$SR/include -I$SR/include/SDL2 \
    lodor-qr.c qrcodegen.c -o lodor-qr \
    -L$SR/lib -lSDL2 -lSDL2_ttf -lpthread -ldl -lm'
file "$QRBIN_OUT" | grep -q aarch64 || { echo "FATAL: lodor-qr is not arm64"; exit 1; }

echo "== building aarch64 SDL frame-helper (lodor-fbhelper) in $TCIMG =="
# The SDL-lane DISPLAY backend for the launch card (task launch-card-v2). Same toolchain +
# /usr/trimui/lib SDL2 as lodor-qr; DISPLAY ONLY (reads no input — input is the Go
# EvdevSource). Built once (arm64) and dropped next to lodor-wizard so spikeHelperPath()
# resolves it as a sibling.
FBSRC="$HERE/fbhelper"
FBBIN_OUT="$FBSRC/lodor-fbhelper"
sh "$FBSRC/build.sh"
file "$FBBIN_OUT" | grep -q aarch64 || { echo "FATAL: lodor-fbhelper is not arm64"; exit 1; }

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
  cp "$PAKSRC/pak.json" "$D/pak.json"
  cp "$PAKSRC/config.json.template" "$D/config.json.template"
  cp "$ENG" "$D/lodor-sync"
  cp "$WIZ" "$D/lodor-wizard"   # launch card (hook 10 calls it; engine resolved as sibling)
  cp "$FBBIN_OUT" "$D/lodor-fbhelper"   # SDL-lane DISPLAY backend (launch card; wizard spawns it as a sibling)
  cp "$CERT" "$D/certs/ca-certificates.crt"
  # Handoff manifests (#27) — LIGHTS statesync on NextUI. Both tg5040/tg5050 are arm64.
  # dir = minarch {TAG}-{core} under .userdata/shared/ (verified off NextUI source:
  # ma_core.c states_dir = SHARED_USERDATA/<tag>-<corename>; note SFC not SNES). Keys =
  # RomM fs_slug verified live (genesis, NOT megadrive; mastersystem, NOT sms). NextUI
  # runs snes9x (full) for SNES — matches Knulli/Android/muOS(post-#11) arm64 snes9x
  # club, not the Miyoo armhf snes9x2005_plus (SNES is within-bitness-group by design).
  #   GBA=mgba is now the FLEET STANDARD (Decisions/2026-07-13-gba-fleet-mgba.md): LodorOS,
  #   muOS, Knulli and Android all run mgba, so GBA states finally sync cross-lane. NextUI
  #   builds mgba itself (CORES+= mgba) and ships it in MGBA.pak/SGB.pak; the Lodor-NextUI
  #   GBA.pak overlay (emus/GBA.pak, staged below) makes the (GBA) tag launch that bundled
  #   mgba so the on-device state format matches this gba=mgba:GBA-mgba manifest entry.
  #   (The gpsp era was the cross-lane orphan.) GG/SMS/MD=picodrive matches LodorOS-my355/Knulli; muOS runs
  #   genesis_plus_gx → that arm64 split is muOS-#11's flag.
  #   PSX/N64 (#14/#5/#6): NOT emitted for NextUI. NextUI's PSX (pcsx_rearmed) and N64
  #   (mupen64plus_next) core assignment through the state-producing minarch path is NOT
  #   confirmed from source — declaring them unverified would fake a capability. Left out
  #   honestly and FLAGGED for on-device confirmation (see flagged-cells list); add here
  #   iff a tg5040/tg5050 check shows those systems run those libretro cores via minarch.
  sh "$MONO/release/mkstatecores.sh" --frontend nextui --arch arm64 --out "$D/statecores.json" \
    nes=fceumm:FC-fceumm gb=gambatte:GB-gambatte gbc=gambatte:GBC-gambatte \
    gba=mgba:GBA-mgba gamegear=picodrive:GG-picodrive \
    mastersystem=picodrive:SMS-picodrive genesis=picodrive:MD-picodrive \
    snes=snes9x:SFC-snes9x >&2 || { echo "nextui statecores emit failed" >&2; exit 1; }
  # D8 whitelist (fix #2 — the fleet-UNIFORM class list; identical on every lane).
  sh "$MONO/release/mkstatecompat.sh" --out "$D/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:armhf,arm64 genesis_plus_gx:arm64 >&2 \
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
  chmod +x "$D/launch.sh" "$D/lodor-sync" "$D/lodor-wizard" "$D/lodor-fbhelper" "$D/bin/romm-run" "$D/bin/romm-syncd" \
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

  # ---- GBA=mgba OVERLAY (Decisions/2026-07-13-gba-fleet-mgba.md) — ships ON THE CARD ----
  # NextUI resolves Emus/<plat>/<TAG>.pak; the (GBA) folder tag -> TAG=GBA. This overlay lands
  # as Emus/<plat>/GBA.pak and OVERRIDES NextUI stock GBA.pak (=gpsp) so the GBA tag launches
  # mgba. DATA-INTEGRITY INVARIANT: the statecores manifest above pins gba=mgba:GBA-mgba, so the
  # device MUST run mgba or it uploads gpsp-format states tagged mgba and corrupts the fleet.
  # launch.sh is structurally identical to NextUI MGBA.pak (EMU_EXE=mgba, CORES_PATH=self);
  # minarch writes states to {TAG}-{core} = GBA-mgba, matching the manifest key. Zero NextUI fork.
  G="$OUT/Emus/$PLAT/GBA.pak"
  mkdir -p "$G"
  cp "$EMUSRC/GBA.pak/launch.sh"  "$G/launch.sh"
  cp "$EMUSRC/GBA.pak/default.cfg" "$G/default.cfg"
  chmod +x "$G/launch.sh"
  # Bundle NextUI OWN ABI-matched mgba core (not the mgba-cert binary) so GBA.pak is
  # self-contained like MGBA.pak. mGBA is a hard Lodor dependency: if MGBACORE is
  # unset/missing we FATAL (below) rather than ship a card with broken GBA save-state sync.
  if [ -n "$MGBACORE" ] && [ -f "$MGBACORE" ]; then
    file "$MGBACORE" | grep -q aarch64 || { echo "FATAL: MGBACORE is not arm64: $MGBACORE"; exit 1; }
    cp "$MGBACORE" "$G/mgba_libretro.so"
  else
    echo "FATAL: MGBACORE unset/missing ($MGBACORE) — mGBA is a hard Lodor dependency:" >&2
    echo "       GBA save-STATE sync (the sync moat) is only deterministic on mgba; provide" >&2
    echo "       NextUI ABI-matched mgba_libretro.so (default under lodor-nextui-stage)." >&2
    exit 1
  fi
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
