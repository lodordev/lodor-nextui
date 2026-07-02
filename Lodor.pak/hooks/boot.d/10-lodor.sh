#!/bin/sh
export LODOR_HOST_OS=nextui
# Lodor boot daemon launcher (NextUI boot.d hook). NextUI's run_hooks.sh runs boot hooks and `wait`s
# on them, so this hook MUST fully detach the long-running daemon (setsid + redirect + &) — otherwise
# boot would block on romm-syncd forever. We return immediately; the daemon keeps running, reparented.
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-tg5040}"
PAKDIR="$SDCARD/Tools/$PLAT/Lodor.pak"

# Game Manager ROOT ENTRY heal (task #131; bottom-sorted + migrated, task #134). MinUI.pak runs
# boot.d BEFORE the first nextui.elf of every boot, so healing here guarantees Roms/"Game Manager
# (LODORGM)" + Emus/<plat>/LODORGM.pak + the Roms/map.txt bottom-sort alias exist before every
# root scan — a partial card update can no longer hide the root row until the next full Lodor.pak
# session. cmp of tiny files: milliseconds, silent, never fatal.
GM_SRC="$PAKDIR/gmpak"
if [ -d "$GM_SRC" ]; then
	GM_TAG="LODORGM"
	GM_DIRNAME="Game Manager ($GM_TAG)"
	GM_DIRNAME_OLD="0) Game Manager ($GM_TAG)"
	GM_EMUDST="$SDCARD/Emus/$PLAT/$GM_TAG.pak"
	if ! cmp -s "$GM_SRC/launch.sh" "$GM_EMUDST/launch.sh" 2>/dev/null; then
		mkdir -p "$GM_EMUDST" 2>/dev/null
		cp -f "$GM_SRC/launch.sh" "$GM_EMUDST/launch.sh" 2>/dev/null && chmod +x "$GM_EMUDST/launch.sh" 2>/dev/null
	fi
	GM_ROMDST="$SDCARD/Roms/$GM_DIRNAME"
	for _gmf in "Open Game Manager.gm" "$GM_DIRNAME.m3u"; do
		if ! cmp -s "$GM_SRC/roms/$_gmf" "$GM_ROMDST/$_gmf" 2>/dev/null; then
			mkdir -p "$GM_ROMDST" 2>/dev/null
			cp -f "$GM_SRC/roms/$_gmf" "$GM_ROMDST/$_gmf" 2>/dev/null
		fi
	done
	# migration (task #134): retire the pre-#134 top-sorted folder — but only once the new folder
	# verifiably exists, so a failed heal never leaves a card with no GM root row at all.
	if [ -d "$SDCARD/Roms/$GM_DIRNAME_OLD" ] && [ -f "$GM_ROMDST/Open Game Manager.gm" ]; then
		rm -rf "$SDCARD/Roms/$GM_DIRNAME_OLD" 2>/dev/null
	fi
	# Roms/map.txt BOTTOM-SORT alias (task #134): NextUI aliases root folders via map.txt and
	# resorts BY THE ALIAS; a leading U+00A0 NBSP (first byte 0xC2 > all ASCII) anchors the row
	# last while rendering as a blank in both shipped fonts. MERGE, never clobber: non-GM lines
	# (user aliases, the engine-owned Continue label) survive verbatim; tmp+rename stays atomic.
	_MAPFILE="$SDCARD/Roms/map.txt"
	_MAPTAB="$(printf '\t')"
	_MAPLINE="$(printf 'Game Manager (%s)\t\302\240Game Manager' "$GM_TAG")"
	if ! grep -qF "$_MAPLINE" "$_MAPFILE" 2>/dev/null; then
		_MAPTMP="$_MAPFILE.tmp.$$"
		{ [ -f "$_MAPFILE" ] && grep -v "^Game Manager ($GM_TAG)$_MAPTAB" "$_MAPFILE" 2>/dev/null
		  printf '%s\n' "$_MAPLINE"; } > "$_MAPTMP" 2>/dev/null && mv -f "$_MAPTMP" "$_MAPFILE" 2>/dev/null
		rm -f "$_MAPTMP" 2>/dev/null
	fi
fi

# Continue ROOT ENTRY heal (task #134): same boot-invariant treatment for the one-press
# resume row — Emus/<plat>/LODORCT.pak + Roms/"0) Continue (LODORCT)" exist before every
# root scan. (The engine writes its data — continue-head.txt + the optional map.txt label —
# on its own cadence; missing data just means the dispatcher shows the honest empty state.)
CT_SRC="$PAKDIR/ctpak"
if [ -d "$CT_SRC" ]; then
	CT_TAG="LODORCT"
	CT_DIRNAME="0) Continue ($CT_TAG)"
	CT_EMUDST="$SDCARD/Emus/$PLAT/$CT_TAG.pak"
	if ! cmp -s "$CT_SRC/launch.sh" "$CT_EMUDST/launch.sh" 2>/dev/null; then
		mkdir -p "$CT_EMUDST" 2>/dev/null
		cp -f "$CT_SRC/launch.sh" "$CT_EMUDST/launch.sh" 2>/dev/null
		chmod +x "$CT_EMUDST/launch.sh" 2>/dev/null
	fi
	CT_ROMDST="$SDCARD/Roms/$CT_DIRNAME"
	for _ctf in "Continue.ct" "$CT_DIRNAME.m3u"; do
		if ! cmp -s "$CT_SRC/roms/$_ctf" "$CT_ROMDST/$_ctf" 2>/dev/null; then
			mkdir -p "$CT_ROMDST" 2>/dev/null
			cp -f "$CT_SRC/roms/$_ctf" "$CT_ROMDST/$_ctf" 2>/dev/null
		fi
	done
fi

DAEMON="$PAKDIR/bin/romm-syncd"
[ -x "$DAEMON" ] || exit 0

# Don't double-start if it's already running.
if pgrep -f "romm-syncd" >/dev/null 2>&1; then exit 0; fi

if command -v setsid >/dev/null 2>&1; then
	setsid "$DAEMON" </dev/null >/dev/null 2>&1 &
else
	"$DAEMON" </dev/null >/dev/null 2>&1 &
fi
exit 0
