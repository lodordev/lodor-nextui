#!/bin/sh
# LODORGM.pak — the Game Manager ROOT ENTRY shim (task #128). NextUI treats
# Roms/"Game Manager (LODORGM)" as a system folder and this pak as its "emulator":
# selecting the root row makes NextUI run
#     '<this script>' '<SDCARD>/Roms/Game Manager (LODORGM)/Open Game Manager.gm'
# exactly like a game launch (MinUI.pak eval). We ignore the dummy entry path ($1) and
# exec the ONE real implementation — Tools/<plat>/Lodor.pak/launch.sh --game-manager —
# so the root entry and the Tools-menu entry can never drift. ZERO NextUI fork: this is
# a plain Emus pak, discovered by hasEmu()/getEmuPath() like any other.
#
# The Lodor launch hooks skip this dummy path by tag guard (*(LODORGM)*), and the entry
# file is non-empty so the fetch hook's 0-byte stub check passes over it even unguarded.
set -u

# Env first (MinUI.pak exports SDCARD_PATH/PLATFORM to everything it launches); derive
# from our own location as a fallback: <SD>/Emus/<plat>/LODORGM.pak/launch.sh.
PAKDIR="$(cd "$(dirname "$0")" && pwd)"
SD="${SDCARD_PATH:-$(cd "$PAKDIR/../../.." && pwd)}"
PLAT="${PLATFORM:-$(basename "$(dirname "$PAKDIR")")}"
TOOLPAK="$SD/Tools/$PLAT/Lodor.pak"

# ---- crash capture (B4): bounded stderr log beside the pak's other logs — the exec below
# carries this redirect into the whole --game-manager session, so a dying line lands here.
# Rotate: keep the newest half once the log passes 64 KB.
GMLOG="$TOOLPAK/gm-stderr.log"
if [ -f "$GMLOG" ] && [ "$(wc -c < "$GMLOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
	tail -c 32768 "$GMLOG" > "$GMLOG.tmp.$$" 2>/dev/null && mv -f "$GMLOG.tmp.$$" "$GMLOG" 2>/dev/null
	rm -f "$GMLOG.tmp.$$" 2>/dev/null
fi
echo "=== $(date +'%F %T' 2>/dev/null) LODORGM dispatcher ===" >> "$GMLOG" 2>/dev/null
exec 2>>"$GMLOG"

# ---- FIRST PAINT (B2): instant feedback before the Tools pak's init work (heal, engine
# warm-up) — the 0.9.1 field jank was exactly this blank window. launch.sh's first ui_msg /
# menu draw killalls the presenter, so this never lingers.
BINPLAT="$PLAT"; [ "$BINPLAT" = "tg3040" ] && BINPLAT="tg5040"
PRESBIN="$TOOLPAK/bin/$BINPLAT/minui-presenter"
if [ -x "$PRESBIN" ]; then
	killall minui-presenter >/dev/null 2>&1 || true
	"$PRESBIN" --message "Opening Game Manager..." --timeout -1 >/dev/null 2>&1 &
fi

TOOL="$TOOLPAK/launch.sh"
if [ -x "$TOOL" ] || [ -f "$TOOL" ]; then
	exec /bin/sh "$TOOL" --game-manager
fi
# Honest degrade: Lodor.pak is gone (deleted from Tools?). Nothing we can draw with —
# exit cleanly so NextUI just returns to the browser instead of hanging on a dead eval.
exit 0
