#!/bin/sh
export LODOR_HOST_OS=nextui
# STATE-ON-LAUNCH (Handoff, task #24 — 2026-07-07: interactive launch
# hooks, card only when something's newer). Sibling of 10-lodor-fetch.sync.sh,
# NOT an edit to it: that hook's save decision matrix (#135) is battle-tested
# and exits early on most branches — a separate .sync.sh runs regardless, and
# NextUI's run_hooks.sh executes us synchronously with the framebuffer free.
#
# Offer = the newest COMPATIBLE server save state this device's ledger has
# never seen (--list-states rows with compat=1 known=0 — content-based, no
# clock trust). One honest prompt via the pak's native minui-list, exactly like
# the save prompt above it. No offer -> completely silent. Dark without
# statecores.json (the engine answers no-manifest and we do nothing). A launch
# is NEVER blocked; placement never destroys (engine invariant 7.1: the slot's
# occupant is uploaded + .bak'd first).

[ "${HOOK_TYPE:-}" = "rom" ] || exit 0
[ -n "${HOOK_ROM_PATH:-}" ] || exit 0
[ -s "$HOOK_ROM_PATH" ] || exit 0   # 0-byte stub: nothing to play states on
case "$HOOK_ROM_PATH" in *"(LODORGM)/"*|*"(LODORCT)/"*) exit 0 ;; esac

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-tg5040}"
PAKDIR="$SDCARD/Tools/$PLAT/Lodor.pak"
RUN="$PAKDIR/bin/romm-run"
[ -x "$RUN" ] || exit 0
# Feature-dark fast path: no manifest, no engine spawn, zero launch cost.
[ -f "$PAKDIR/statecores.json" ] || exit 0

BINPLAT="$PLAT"; [ "$BINPLAT" = "tg3040" ] && BINPLAT="tg5040"
LISTBIN="$PAKDIR/bin/$BINPLAT/minui-list"
PRESBIN="$PAKDIR/bin/$BINPLAT/minui-presenter"
[ -x "$LISTBIN" ] || exit 0

SYNCLOG="$PAKDIR/last-sync.log"
slog() { echo "$(date +'%F %T') $*" >> "$SYNCLOG" 2>/dev/null; }

GAME="$(basename "$HOOK_ROM_PATH")"; GAME="${GAME%.*}"
case "$GAME" in
	"✘ "*)   GAME="${GAME#"✘ "}" ;;
	"✓ "*)   GAME="${GAME#"✓ "}" ;;
	"[^] "*) GAME="${GAME#"[^] "}" ;;
	"[v] "*) GAME="${GAME#"[v] "}" ;;
esac

trap 'killall minui-presenter >/dev/null 2>&1 || true; killall minui-list >/dev/null 2>&1 || true' EXIT INT TERM HUP QUIT

states_raw="$("$RUN" --list-states "$HOOK_ROM_PATH" 2>/dev/null)"
strc=$?
# Offline / unreachable / no manifest -> silent launch. NEVER claim "no states"
# when we couldn't ask; the reason token is in the engine output if logs matter.
[ "$strc" = 0 ] || { slog "states: action=offline (rc=$strc) game=$GAME"; exit 0; }

# Newest unseen compatible row: prefix each candidate with its age= for a
# numeric sort, take the youngest, then strip the sort key.
best_line="$(printf '%s\n' "$states_raw" | grep '^LISTSTATE ' \
	| grep -F ' compat=1 ' | grep -F ' known=0 ' \
	| sed -n 's/.* age=\([0-9][0-9]*\).*/\1 &/p' | sort -n | head -1 \
	| sed 's/^[0-9]* //')"
[ -n "$best_line" ] || exit 0   # nothing newer -> zero friction (the design)

sid="$(printf '%s' "$best_line" | sed -n 's/.*id=\([0-9][0-9]*\).*/\1/p')"
[ -n "$sid" ] || exit 0
sorigin="$(printf '%s' "$best_line" | sed -n 's/.* origin=\([^ ]*\).*/\1/p')"
sfrom="another device"
case "$sorigin" in
	lodor/lodoros/*) sfrom="a LodorOS device" ;;
	lodor/nextui/*)  sfrom="a NextUI device" ;;
	lodor/muos/*)    sfrom="a muOS device" ;;
	lodor/knulli/*)  sfrom="a Knulli device" ;;
	lodor/onion/*)   sfrom="an OnionOS device" ;;
esac

slog "states: offer id=$sid from=$sorigin game=$GAME"
SLST="/tmp/lodor-state-list"; SOUT="/tmp/lodor-state-out"
: > "$SLST"; rm -f "$SOUT"
printf '%s\n' "Just play" >> "$SLST"
printf '%s\n' "Continue from that state" >> "$SLST"
killall minui-presenter >/dev/null 2>&1 || true
"$LISTBIN" --disable-auto-sleep --file "$SLST" --format text \
	--title "Newer save state from $sfrom" --confirm-text "SELECT" --cancel-text "PLAY" \
	--write-location "$SOUT"
lrc=$?
sel="$(cat "$SOUT" 2>/dev/null)"

if [ "$lrc" = 0 ] && [ "$sel" = "Continue from that state" ]; then
	[ -x "$PRESBIN" ] && "$PRESBIN" --message "Placing state…" --timeout -1 >/dev/null 2>&1 &
	if "$RUN" --pull-state "$HOOK_ROM_PATH" --state-id "$sid" 2>/dev/null | grep -q 'placedstate=1'; then
		killall minui-presenter >/dev/null 2>&1 || true
		slog "states: placed id=$sid game=$GAME"
		[ -x "$PRESBIN" ] && "$PRESBIN" --message "State placed — load it from the in-game menu" --timeout 2 >/dev/null 2>&1
	else
		killall minui-presenter >/dev/null 2>&1 || true
		slog "states: place FAILED id=$sid game=$GAME (launching anyway)"
		[ -x "$PRESBIN" ] && "$PRESBIN" --message "Couldn't place the state — launching anyway" --timeout 2 >/dev/null 2>&1
	fi
else
	slog "states: declined id=$sid game=$GAME"
fi
exit 0
