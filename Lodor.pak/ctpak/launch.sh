#!/bin/sh
# LODORCT.pak — the one-press "Continue" ROOT ENTRY dispatcher (task #134). NextUI treats
# Roms/"0) Continue (LODORCT)" as a system folder ("0) " digit-prefix sorts it FIRST;
# trimSortingMeta renders "Continue"; the engine may alias it to "0) Continue: <Game>" via
# Roms/map.txt) and this pak as its "emulator": one press on the root row makes NextUI run
#     '<this script>' '<SDCARD>/Roms/0) Continue (LODORCT)/Continue.ct'
# We ignore the dummy path ($1) and RESUME the newest cross-device game: read the head the
# engine persists for exactly this purpose (continue-head.txt — offline, no server ask),
# bracket the REAL rom with the SAME Lodor fetch/push hooks a normal NextUI launch gets
# (download-on-launch + restore-on-launch + save push), and launch the REAL emulator pak
# as a child. ZERO NextUI fork — a plain Emus pak plus data files.
#
# NextUI's own run_hooks.sh DOES fire around this dispatcher with the DUMMY path — both
# Lodor hooks skip it by tag guard (*"(LODORCT)/"*), so the real work happens exactly
# once, in here, with the REAL path.
set -u

PAKDIR="$(cd "$(dirname "$0")" && pwd)"
SD="${SDCARD_PATH:-$(cd "$PAKDIR/../../.." && pwd)}"
PLAT="${PLATFORM:-$(basename "$(dirname "$PAKDIR")")}"
TOOLPAK="$SD/Tools/$PLAT/Lodor.pak"

# ---- crash capture (B4): bounded stderr log beside the pak's other logs. If hardware
# misbehaves again we get the dying line, not a description. Rotate: keep the newest half
# once the log passes 64 KB.
CTLOG="$TOOLPAK/gm-stderr.log"
if [ -f "$CTLOG" ] && [ "$(wc -c < "$CTLOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
	tail -c 32768 "$CTLOG" > "$CTLOG.tmp.$$" 2>/dev/null && mv -f "$CTLOG.tmp.$$" "$CTLOG" 2>/dev/null
	rm -f "$CTLOG.tmp.$$" 2>/dev/null
fi
echo "=== $(date +'%F %T' 2>/dev/null) LODORCT dispatcher ===" >> "$CTLOG" 2>/dev/null
exec 2>>"$CTLOG"

BINPLAT="$PLAT"; [ "$BINPLAT" = "tg3040" ] && BINPLAT="tg5040"
PRESBIN="$TOOLPAK/bin/$BINPLAT/minui-presenter"

# say <msg> [timeout] — presenter message; -1 persists until killed (backgrounded).
say() {
	killall minui-presenter >/dev/null 2>&1 || true
	[ -x "$PRESBIN" ] || return 0
	if [ "${2:-3}" = "-1" ]; then
		"$PRESBIN" --message "$1" --timeout -1 >/dev/null 2>&1 &
	else
		"$PRESBIN" --message "$1" --timeout "${2:-3}" >/dev/null 2>&1
	fi
	return 0
}

# ---- FIRST PAINT (B2): instant feedback before ANY other work — the 0.9.1 field jank was
# this exact window (blacked rows, then a surprise heal message) with nothing on screen.
say "Continuing..." -1

# scrub_recents (B3): remove our dispatchers' dummy rows from NextUI's Recently Played /
# Game Switcher list — they are affordances, not games, and the Continue dummy in the
# switcher is the prime blacked-row suspect. Safe window: the launcher is dead while an
# "emulator" (us) runs. Real entries and their aliases are preserved verbatim; tmp+rename
# keeps the write atomic on FAT32/exFAT. The engine's recents-merge drops these rows too,
# so a sync can never re-inject them.
scrub_recents() {
	_rf="$SD/.userdata/shared/.minui/recent.txt"
	[ -f "$_rf" ] || return 0
	grep -qE '\((LODORGM|LODORCT)\)/' "$_rf" 2>/dev/null || return 0
	_rt="$_rf.tmp.$$"
	grep -vE '\((LODORGM|LODORCT)\)/' "$_rf" > "$_rt" 2>/dev/null && mv -f "$_rt" "$_rf" 2>/dev/null
	rm -f "$_rt" 2>/dev/null
	return 0
}

# empty_state <msg> — honest terminal message (nothing to resume / nothing launchable),
# recents scrubbed on the way out so the dummy row never lingers.
empty_state() {
	say "$1" 4
	scrub_recents
	exit 0
}

# ---- resolve the newest cross-device game from the engine-persisted head ----
# The head is a newest-first LIST (task #135): an entry's exact path can drift between the
# engine's write and this press — the post-launch hook renames ✘→✓ the moment a downloaded
# game exits (the Smart Pro 2026-07-03 field bug: head said "✘ …Emerald… (RomM).gba", the
# card held "✓ …", and one press on "Continue: Pokemon - Emerald Version" answered "Nothing
# to continue yet"). So each entry is resolved TOLERANTLY (exact -> other download-state
# marker -> coexist (RomM)/clean twin) and an unresolvable entry falls through to the next,
# every decision logged to gm-stderr.log + last-sync.log.
HEAD_FILE="${SHARED_USERDATA_PATH:-$SD/.userdata/shared}/Lodor/continue-head.txt"
[ -f "$HEAD_FILE" ] || empty_state "Nothing to continue yet - play something!"
TAB="$(printf '\t')"

SYNCLOG="$TOOLPAK/last-sync.log"
ctlog() {
	echo "$(date +'%F %T' 2>/dev/null) $*" >> "$SYNCLOG" 2>/dev/null
	echo "$*" >&2   # gm-stderr.log (fd2 is redirected there above)
}

# strip_marker <name> -> stdout: name minus any leading download-state marker (browser chrome).
strip_marker() {
	_sm="$1"
	case "$_sm" in
		"✘ "*)   _sm="${_sm#"✘ "}" ;;
		"✓ "*)   _sm="${_sm#"✓ "}" ;;
		"[^] "*) _sm="${_sm#"[^] "}" ;;
		"[v] "*) _sm="${_sm#"[v] "}" ;;
	esac
	printf '%s' "$_sm"
}

# resolve_entry <sd-relative path> — sets ROM (absolute) + VIA on success. Tries the exact
# path, then the same basename under each marker variant (✓ first — prefer a downloaded
# copy over a stub), then the coexist twin's name (" (RomM)" added/stripped before the
# extension) under each marker variant. The twins are the SAME game on the server (one
# rom_id), so resuming the surviving twin is the honest fallback while the twin cleanup
# (C2) retires the duplicates.
resolve_entry() {
	_rel="$1"; VIA=""
	if [ -f "$SD/$_rel" ]; then ROM="$SD/$_rel"; VIA=exact; return 0; fi
	_dir="${_rel%/*}"; [ "$_dir" = "$_rel" ] && _dir=""
	_bare="$(strip_marker "${_rel##*/}")"
	for _cand in "✓ $_bare" "✘ $_bare" "$_bare" "[v] $_bare" "[^] $_bare"; do
		if [ -f "$SD/$_dir/$_cand" ]; then ROM="$SD/$_dir/$_cand"; VIA=marker; return 0; fi
	done
	# coexist twin (only for names with an extension to split on)
	case "$_bare" in
		*.*)
			_ext="${_bare##*.}"; _stem="${_bare%.*}"
			case "$_stem" in
				*" (RomM)") _twin="${_stem% (RomM)}.$_ext" ;;
				*)          _twin="$_stem (RomM).$_ext" ;;
			esac
			for _cand in "✓ $_twin" "✘ $_twin" "$_twin"; do
				if [ -f "$SD/$_dir/$_cand" ]; then ROM="$SD/$_dir/$_cand"; VIA=twin; return 0; fi
			done
			;;
	esac
	return 1
}

ROM=""; DISP=""; REL=""; _n=0
while IFS= read -r _hl || [ -n "$_hl" ]; do
	[ -n "$_hl" ] || continue
	_rel="${_hl%%"$TAB"*}"
	_d="${_hl#*"$TAB"}"; [ "$_d" = "$_hl" ] && _d=""
	_rel="${_rel#/}"
	[ -n "$_rel" ] || continue
	_n=$((_n+1))
	# paranoia: a head that points at a dispatcher dummy must never recurse
	case "$_rel" in *"(LODORCT)"*|*"(LODORGM)"*)
		ctlog "continue: entry $_n is a dispatcher dummy -> skipped"
		continue ;;
	esac
	if resolve_entry "$_rel"; then
		REL="${ROM#"$SD"/}"
		DISP="$_d"
		ctlog "continue: entry $_n resolved via=$VIA rom='$REL'"
		break
	fi
	ctlog "continue: entry $_n not on card ('$_rel') -> trying next"
	ROM=""
done < "$HEAD_FILE"

if [ -z "$ROM" ]; then
	[ "$_n" = 0 ] && empty_state "Nothing to continue yet - play something!"
	ctlog "continue: no head entry resolvable (entries=$_n) -> suggest Sync"
	empty_state "Continue list is out of date - run Sync in Tools"
fi
if [ -z "$DISP" ]; then DISP="$(strip_marker "$(basename "$ROM")")"; DISP="${DISP%.*}"; fi

say "Continuing $DISP..." -1

# TAG = trailing "(TAG)" of the game's system folder; emulator = NextUI's getEmuPath order
# (user Emus/<plat>/<TAG>.pak first, then the stock .system pak).
SYSDIR="${REL#Roms/}"; SYSDIR="${SYSDIR%%/*}"
TAG="${SYSDIR##*(}"; TAG="${TAG%)}"
if [ -z "$TAG" ] || [ "$TAG" = "$SYSDIR" ]; then
	empty_state "Can't tell which system $DISP belongs to"
fi
EMU="$SD/Emus/$PLAT/$TAG.pak/launch.sh"
[ -f "$EMU" ] || EMU="$SD/.system/$PLAT/paks/Emus/$TAG.pak/launch.sh"
[ -f "$EMU" ] || empty_state "No emulator installed for $SYSDIR"

# ---- hook brackets: the installed copies (what a normal launch runs), pak copies as the
# fallback on a card whose hooks aren't wired yet.
HOOKS="$SD/.userdata/$PLAT/.hooks"
PREHOOK="$HOOKS/pre-launch.d/10-lodor-fetch.sync.sh"
[ -f "$PREHOOK" ] || PREHOOK="$TOOLPAK/hooks/pre-launch.d/10-lodor-fetch.sync.sh"
PUSHHOOK="$HOOKS/post-launch.d/90-lodor-pushsave.sh"
[ -f "$PUSHHOOK" ] || PUSHHOOK="$TOOLPAK/hooks/post-launch.d/90-lodor-pushsave.sh"

export SDCARD_PATH="$SD" PLATFORM="$PLAT"
export HOOK_TYPE=rom HOOK_ROM_PATH="$ROM" HOOK_EMU_PATH="$EMU" HOOK_CMD="lodor-continue" HOOK_LAST=""

# FETCH BRACKET — download-on-launch (0-byte stub -> real, verified bytes) + the restore
# picker, exactly as a normal launch of the REAL game would get.
if [ -f "$PREHOOK" ]; then
	killall minui-presenter >/dev/null 2>&1 || true   # the hook owns the screen now
	HOOK_PHASE=pre sh "$PREHOOK" || true
fi

# Still a 0-byte stub (download failed / offline): launching it would strand the user on
# the emulator's own load-error screen — stop here with the honest cause instead.
[ -s "$ROM" ] || empty_state "Couldn't download $DISP - check Wi-Fi"

killall minui-presenter >/dev/null 2>&1 || true
sh "$EMU" "$ROM"   # CHILD, not exec — the push bracket + scrub below must still run

# PUSH BRACKET — save push (verified / offline-staged) + the ✘->✓ marker reconcile.
if [ -f "$PUSHHOOK" ]; then
	HOOK_PHASE=post sh "$PUSHHOOK" || true
fi

scrub_recents
exit 0
