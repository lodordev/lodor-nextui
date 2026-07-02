#!/bin/bash
# rootscan/run.sh — task #128/#131 root-entry visibility + #134 ORDER proof harness.
#
# Compiles the ACTUAL NextUI root-scan code (hide/getEmuName/getDisplayName from
# workspace/all/common/utils.c compiled as-is; hasEmu/hasRoms/getRoms extracted
# VERBATIM from workspace/all/nextui/nextui.c by brace-counting — no reimplementation)
# against a replica of our on-card layout, and asserts the Game Manager root row
# survives the scan, sorts LAST (the Roms/map.txt NBSP alias, task #134) and renders
# clean. This is the closest off-device stand-in for "does the row render":
# everything below the scan is plain list rendering with a text fallback
# (nextui.c list_show_entry_names safeguard), so scan inclusion == a visible row.
#
# Layout under test comes from the repo's real staged sources (gmpak/roms/*), not
# hand-typed names, so a staging rename breaks this gate too.
#
# Env:
#   NEXTUI_SRC   NextUI clone root (default /mnt/cache/tmp/NextUI). Missing => WARN+skip
#                (exit 0) so check.sh stays green on hosts without the clone.
# Requires docker (gcc:13); missing docker => WARN+skip. SDCARD_PATH is baked to /work/sd
# at compile time, so the harness only ever runs inside the container.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
NEXTUI_DIR="$(cd "$HERE/../.." && pwd)"   # integrations/nextui
NEXTUI_SRC="${NEXTUI_SRC:-/mnt/cache/tmp/NextUI}"

SRC_UI="$NEXTUI_SRC/workspace/all/nextui/nextui.c"
SRC_COMMON="$NEXTUI_SRC/workspace/all/common"
if [ ! -f "$SRC_UI" ] || [ ! -f "$SRC_COMMON/utils.c" ]; then
	echo "WARN: rootscan skipped — NextUI clone not found at $NEXTUI_SRC (set NEXTUI_SRC)"
	exit 0
fi

WORK="$(mktemp -d /tmp/lodor-rootscan.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/inc" "$WORK/gen"

# ---- 1. verbatim extraction from the clone ----
# contiguous SDL-free container region: Array/Hash/Entry/EntryArray/IntArray
awk '/^typedef struct Array \{/{on=1} /^typedef struct Directory \{/{exit} on{print}' \
	"$SRC_UI" > "$WORK/gen/containers.c"
# single functions by signature + brace counting (literal prefix match, not regex —
# awk -v mangles backslash escapes)
extract_fn() { # $1=literal opening-line prefix, $2=outfile
	awk -v pfx="$1" '
		!on && substr($0, 1, length(pfx)) == pfx {on=1}
		on {
			print
			n=gsub(/\{/,"{"); m=gsub(/\}/,"}")
			depth += n - m
			if (started && depth==0) exit
			if (n>0) started=1
		}' "$SRC_UI" > "$2"
	[ -s "$2" ] || { echo "GATE FAIL: extraction empty for $1"; exit 1; }
}
extract_fn 'static int hasEmu(char* emu_name) {' "$WORK/gen/hasEmu.c"
extract_fn 'static int hasRoms(char* dir_name) {' "$WORK/gen/hasRoms.c"
extract_fn 'static Array* getRoms()'              "$WORK/gen/getRoms.c"
for f in containers hasEmu hasRoms getRoms; do
	[ -s "$WORK/gen/$f.c" ] || { echo "GATE FAIL: empty extraction $f"; exit 1; }
done

# ---- 2. compile-time platform shim (tg5040 values, SD root redirected to the replica) ----
cat > "$WORK/inc/platform.h" <<'EOF'
#ifndef PLATFORM_H
#define PLATFORM_H
#define SDCARD_PATH "/work/sd"
#ifndef PLATFORM
#define PLATFORM "tg5040"
#endif
#endif
EOF
cp "$SRC_COMMON/utils.c" "$SRC_COMMON/utils.h" "$SRC_COMMON/defines.h" "$WORK/src/"
cp "$HERE/main.c" "$WORK/main.c"

# ---- 3. replica card tree, from the repo's REAL staged sources ----
SD="$WORK/sd"
GM_DIR="$SD/Roms/Game Manager (LODORGM)"
CT_DIR="$SD/Roms/0) Continue (LODORCT)"
mkdir -p "$GM_DIR" "$SD/Emus/tg5040/LODORGM.pak" \
	"$CT_DIR" "$SD/Emus/tg5040/LODORCT.pak" \
	"$SD/Roms/Game Boy Advance (GBA)" "$SD/Emus/tg5040/GBA.pak" \
	"$SD/Roms/Sony PlayStation (PS)" "$SD/Emus/tg5040/PS.pak" \
	"$SD/Roms/Nintendo 64 (N64)"
cp "$NEXTUI_DIR/Lodor.pak/gmpak/roms/Open Game Manager.gm" "$GM_DIR/"
cp "$NEXTUI_DIR/Lodor.pak/gmpak/roms/Game Manager (LODORGM).m3u" "$GM_DIR/"
cp "$NEXTUI_DIR/Lodor.pak/gmpak/launch.sh" "$SD/Emus/tg5040/LODORGM.pak/launch.sh"
cp "$NEXTUI_DIR/Lodor.pak/ctpak/roms/Continue.ct" "$CT_DIR/"
cp "$NEXTUI_DIR/Lodor.pak/ctpak/roms/0) Continue (LODORCT).m3u" "$CT_DIR/"
cp "$NEXTUI_DIR/Lodor.pak/ctpak/launch.sh" "$SD/Emus/tg5040/LODORCT.pak/launch.sh"
echo rom > "$SD/Roms/Game Boy Advance (GBA)/Test Game.gba"
echo ok  > "$SD/Emus/tg5040/GBA.pak/launch.sh"
# PS control: sorts AFTER "Game Manager" alphabetically, so "GM last" is a real
# assertion (not "second of two") and the nomap degrade (GBA < GM < PS) is provable.
echo rom > "$SD/Roms/Sony PlayStation (PS)/Test Disc.bin"
echo ok  > "$SD/Emus/tg5040/PS.pak/launch.sh"
echo rom > "$SD/Roms/Nintendo 64 (N64)/orphan.n64"   # no pak => must be filtered
# The heal-written Roms/map.txt NBSP alias (task #134): the EXACT bytes the pak's
# root_map_selfheal/boot heal write — U+00A0 (0xC2 0xA0) + "Game Manager".
printf 'Game Manager (LODORGM)\t\302\240Game Manager\n' > "$SD/Roms/map.txt"

# ---- 4. compile + run in the gcc:13 container (x86; code under test is arch-agnostic libc) ----
# Five phases:
#   present         — the shipped layout: GM row survives, sorts LAST (NBSP alias,
#                     after the PS control), exact alias bytes reach the renderer.
#   absent-emupak   — Emus/<plat>/LODORGM.pak removed: hasEmu fails, row MUST drop
#   absent-romsdir  — Roms/"Game Manager (LODORGM)" removed: row MUST drop
#   nomap           — Roms/map.txt removed: GRACEFUL DEGRADE — row present, plain
#                     "Game Manager", alphabetical (GBA < GM < PS); Continue still first.
#   ctlabel         — map.txt + the engine's dynamic label line: Continue row stays
#                     first and renders "Continue: Zelda".
# The two absent phases reproduce the 2026-07-02 on-device symptom (row missing, Tools -> Lodor
# fine) and prove artifact PRESENCE is the only lever — i.e. the fix is the boot/pre-gate heal,
# not a rename.
if ! command -v docker >/dev/null 2>&1; then
	echo "WARN: rootscan skipped — docker unavailable (needs gcc:13 image)"
	exit 0
fi
BUILD='cc -O0 -Wno-unused-function -I/work/inc -I/work/src -o /work/harness /work/main.c /work/src/utils.c'
docker run --rm -v "$WORK":/work gcc:13 bash -c "$BUILD && /work/harness present" \
	|| { echo "== rootscan: FAIL (present phase) =="; exit 1; }

mv "$SD/Emus/tg5040/LODORGM.pak" "$WORK/LODORGM.pak.stash"
docker run --rm -v "$WORK":/work gcc:13 /work/harness absent \
	|| { echo "== rootscan: FAIL (absent-emupak phase) =="; exit 1; }
mv "$WORK/LODORGM.pak.stash" "$SD/Emus/tg5040/LODORGM.pak"

mv "$GM_DIR" "$WORK/gmdir.stash"
docker run --rm -v "$WORK":/work gcc:13 /work/harness absent \
	|| { echo "== rootscan: FAIL (absent-romsdir phase) =="; exit 1; }
mv "$WORK/gmdir.stash" "$GM_DIR"

mv "$SD/Roms/map.txt" "$WORK/map.txt.stash"
docker run --rm -v "$WORK":/work gcc:13 /work/harness nomap \
	|| { echo "== rootscan: FAIL (nomap phase) =="; exit 1; }
mv "$WORK/map.txt.stash" "$SD/Roms/map.txt"

# ctlabel: the ENGINE's dynamic Continue label line joins the heal's GM alias — the row
# must stay FIRST (digit-prefixed sort key) and render "Continue: Zelda" post-trim.
printf '0) Continue (LODORCT)\t0) Continue: Zelda\n' >> "$SD/Roms/map.txt"
docker run --rm -v "$WORK":/work gcc:13 /work/harness ctlabel \
	|| { echo "== rootscan: FAIL (ctlabel phase) =="; exit 1; }

echo "== rootscan: PASS (present + 2 negative phases + nomap degrade + ctlabel) =="
exit 0
