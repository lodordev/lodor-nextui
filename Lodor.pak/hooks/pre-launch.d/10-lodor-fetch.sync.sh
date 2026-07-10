#!/bin/sh
export LODOR_HOST_OS=nextui
# Keep a fetch-on-launch download IN PLACE: NextUI re-launches the ORIGINALLY selected ROM path via
# eval $CMD right after this synchronous hook and a pre-launch hook cannot redirect/cancel that launch
# (NextUI HOOKS.md), and the SD card is exFAT (no symlinks). Moving the file out now would make the
# launch open a dead path. The engine downloads in place; the post-launch hook flips the cloud (✘) ->
# on-device (✓) marker once the game exits (the safe window to rename), carrying the save with it.
export LODOR_NO_RELOCATE=1
# Lodor fetch-on-launch + restore-on-launch (NextUI pre-launch hook).
#
# SYNCHRONOUS by the .sync.sh suffix: NextUI's run_hooks.sh runs this to completion BEFORE the
# emulator launches, and nextui.elf has already exited — so the framebuffer is FREE for us to draw
# on (show2.elf for the download bar; minui-list/minui-presenter for the restore prompt). HOST
# RENDERING ONLY: every RomM decision (resolve, stream, verify, which saves exist, what restoring
# does) lives in the Lodor engine; this hook only renders status and shells out via bin/romm-run.
#
# Env exported by NextUI's MinUI.pak launch.sh / run_hooks.sh:
#   HOOK_TYPE      = "rom" | "pak"
#   HOOK_ROM_PATH  = absolute path to the selected ROM (when HOOK_TYPE=rom)
#   SDCARD_PATH, PLATFORM
#
# Two jobs, in order:
#   1. If the ROM is a 0-byte Lodor stub -> download it, showing honest "Downloading <game>… NN%".
#   2. Once the ROM is present (just-downloaded or already real) -> ask the engine for server saves
#      and gate on the FULL decision matrix (workstream A3, 2026-07-02; STRICT per task #135 —
#      the gate is the LOCAL= trailer, judged against the save THIS launch will load, never a
#      coexist twin's; the row-level CURRENT tag is GM display truth only):
#        LOCAL=current (launched save == newest revision)   -> SILENT launch (no friction)
#        server saves exist but NO local save (LOCAL=none)  -> pull newest SILENTLY (first play of
#                                                              this game on this device — nothing
#                                                              to lose, nothing worth a prompt)
#        newer/foreign newest + a local save exists         -> PROMPT "Newer save from <device>"
#        offline / list failed (rc!=0)                      -> SILENT launch (honest degrade)
#      EVERY branch logs one reason line to last-sync.log + hook-launch.log:
#        saves: listed=<N> newest=<current|foreign|none> action=<prompted|silent|pulled|offline>
#      so the next field diagnosis is one log read — the 2026-07-02 Smart Pro session burned hours
#      because "no server saves" and "server unreachable" were indistinguishable.

[ "${HOOK_TYPE:-}" = "rom" ] || exit 0
[ -n "${HOOK_ROM_PATH:-}" ] || exit 0
[ -f "$HOOK_ROM_PATH" ] || exit 0

# Game Manager / Continue ROOT ENTRIES (tasks #128/#134): the dummy entries under
# Roms/"Game Manager (LODORGM)"/ and Roms/"0) Continue (LODORCT)"/ are launcher affordances,
# not games — NextUI "launches" them to open the Game Manager / the resume dispatcher (which
# runs THIS hook itself against the REAL game). Nothing to download, no saves to offer: skip
# entirely (belt: both entry files ship NON-EMPTY, so the 0-byte stub check below could never
# mistake them for cloud stubs even without this guard).
case "$HOOK_ROM_PATH" in *"(LODORGM)/"*|*"(LODORCT)/"*) exit 0 ;; esac

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-tg5040}"
PAKDIR="$SDCARD/Tools/$PLAT/Lodor.pak"
RUN="$PAKDIR/bin/romm-run"
[ -x "$RUN" ] || exit 0

# minui-list / minui-presenter live under bin/<tg5040|tg5050>; tg3040 reuses the tg5040 build.
BINPLAT="${PLATFORM:-tg5040}"
[ "$BINPLAT" = "tg3040" ] && BINPLAT="tg5040"
LISTBIN="$PAKDIR/bin/$BINPLAT/minui-list"
PRESBIN="$PAKDIR/bin/$BINPLAT/minui-presenter"

HOOKLOG="$PAKDIR/hook-launch.log"
hlog() { echo "$(date +'%F %T') $*" >> "$HOOKLOG" 2>/dev/null; }
# slog — the A3 decision line goes to last-sync.log TOO (the first log a field diagnosis reads),
# in addition to the hook's own log.
SYNCLOG="$PAKDIR/last-sync.log"
slog() { hlog "$*"; echo "$(date +'%F %T') $*" >> "$SYNCLOG" 2>/dev/null; }

# Game display name = ROM basename without extension, minus any leading download-state marker
# ("✘ "/"✓ ", legacy "[^] "/"[v] ") — the marker is browser chrome, not part of the game's name
# (task #126: it must never leak into text we present as the game).
GAME="$(basename "$HOOK_ROM_PATH")"; GAME="${GAME%.*}"
case "$GAME" in
	"✘ "*)   GAME="${GAME#"✘ "}" ;;
	"✓ "*)   GAME="${GAME#"✓ "}" ;;
	"[^] "*) GAME="${GAME#"[^] "}" ;;
	"[v] "*) GAME="${GAME#"[v] "}" ;;
esac

# Shared on-screen presenter (show2.elf). SHOW2_LOGO need not exist (show2 draws text-only).
SHOW2_LOGO="$PAKDIR/res/lodor.png"
SHOW2_LOGFN="hlog"
. "$PAKDIR/lib/show2-lib.sh" 2>/dev/null

# Always free the presenter + framebuffer on the way out, no matter how we exit.
trap 'ui_stop; killall minui-presenter >/dev/null 2>&1 || true; killall minui-list >/dev/null 2>&1 || true' EXIT INT TERM HUP QUIT

# --------------------------------------------------------------------------------------------------
# 1. DOWNLOAD-ON-LAUNCH — only for a 0-byte stub. A real (already-downloaded) ROM is left alone.
#    Multi-disc (lodor#7 disc-1-first): this lands DISC 1 ONLY + the full .m3u; later discs
#    arrive via section 1b on relaunches and the daemon prefetch in the background.
# --------------------------------------------------------------------------------------------------
STUB_FILLED=0
if [ ! -s "$HOOK_ROM_PATH" ]; then
	hlog "=== fetch-on-launch: $HOOK_ROM_PATH (0-byte stub) ==="
	rm -f /tmp/dl-progress /tmp/romm-phase 2>/dev/null
	ui_begin "Downloading $GAME…"

	# Run the engine download in the background so we can stream progress to the screen.
	"$RUN" --download "$HOOK_ROM_PATH" >/dev/null 2>&1 &
	dlpid=$!

	# Bridge the engine side-channels -> show2: a numeric /tmp/dl-progress drives the bar + a
	# "Downloading <game>… NN%" line; before the transfer starts (clock/connect) we mirror the
	# engine's human phase label from /tmp/romm-phase. Never fabricate forward progress.
	while kill -0 "$dlpid" 2>/dev/null; do
		pct=""; [ -f /tmp/dl-progress ] && pct="$(cat /tmp/dl-progress 2>/dev/null)"
		case "$pct" in
			''|*[!0-9]*)
				ph=""; [ -f /tmp/romm-phase ] && ph="$(cat /tmp/romm-phase 2>/dev/null)"
				[ -n "$ph" ] && ui_set "$ph"
				;;
			*)
				ui_set "Downloading $GAME…  ${pct}%" "$pct"
				;;
		esac
		sleep 0.3
	done
	wait "$dlpid"; dlrc=$?
	hlog "download rc=$dlrc size=$(wc -c < "$HOOK_ROM_PATH" 2>/dev/null)"

	# HONEST verification: success requires rc=0 AND the file is now real (non-empty).
	if [ "$dlrc" = 0 ] && [ -s "$HOOK_ROM_PATH" ]; then
		ui_set "Downloaded ✓" 100
		sleep 1
		ui_stop
		STUB_FILLED=1
	else
		# Accepted-degradation: a pre-launch hook cannot cancel the launch, so the emulator still
		# opens the (intact, 0-byte) stub and fails fast with its own load error — the engine
		# restores the stub on every failure path, never leaving a corrupt partial file. We never
		# mask the failure; the cause shown maps the engine/romm-run exit honestly (task #120/#124).
		# #2: romm-run's RESERVED wrapper codes are distinct now — 101 pak-broken, 102 Wi-Fi down
		# (2 kept for a stale pre-#2 wrapper); rc=4 is the engine's ran-but-errored (a server/
		# transfer problem, NOT Wi-Fi); an UNKNOWN rc never claims "check Wi-Fi". #3: every failure
		# splash says the emulator screen that follows WILL fail, so the stub's load error reads
		# as expected instead of as a second mystery.
		case "$dlrc" in
			6) # PAIRING_EXPIRED contract (engine exit 6): flag it for the Tools-menu banner too.
			   : > "$PAKDIR/.pairing-expired" 2>/dev/null
			   ui_error "Pairing expired — open Tools > Lodor to re-pair. The game screen that follows will fail to open — that's expected. Re-pair and launch again." ;;
			2|102) ui_error "Wi-Fi not connected — enable it in NextUI Settings. The game screen that follows will fail to open — that's expected. Fix the connection and launch again." ;;
			3) ui_error "Couldn't reach your server — check the server or your connection. The game screen that follows will fail to open — that's expected. Fix the connection and launch again." ;;
			4) ui_error "The server had a problem sending this game — try again. The game screen that follows will fail to open — that's expected. Fix the connection and launch again." ;;
			101) ui_error "Lodor is broken on this card — reinstall it from the Pak Store. The game screen that follows will fail to open — that's expected. Reinstall Lodor and launch again." ;;
			*) ui_error "Couldn't download $GAME — unknown cause, try again (details in last-sync.log). The game screen that follows will fail to open — that's expected." ;;
		esac
		hlog "download FAILED (rc=$dlrc) — leaving 0-byte stub; emulator will surface the load error"
		exit 0
	fi
fi

# --------------------------------------------------------------------------------------------------
# 1b. NEXT-DISC FETCH (lodor#7 disc-1-first) — the ROM is a REAL (non-empty) .m3u whose disc set
#     is incomplete (later discs are 0-byte stubs / absent). The 0-byte-stub gate above can't see
#     this state — a populated .m3u isn't a stub — so without this re-trigger discs 2+ would
#     strand forever. Fetch the NEXT missing disc with the same honest progress UX as the stub
#     download. NEVER gates the launch (a pre-launch hook can't cancel it anyway): with disc 1
#     present the game plays regardless of this fetch's outcome, so a failure is logged + a brief
#     honest splash, then the launch proceeds. Skipped right after a stub fill (disc 1 just
#     landed this launch — one disc per launch; the daemon prefetch completes the set). NextUI
#     owns the radio: offline the engine fails fast and we launch on disc 1 as-is.
# --------------------------------------------------------------------------------------------------
# Resolve the playlist: the .m3u itself, or the sibling "<Game>.m3u" beside a disc file's folder.
m3u_for() {
	case "$1" in
		*.m3u) printf '%s' "$1"; return 0 ;;
	esac
	_gd=$(dirname "$1"); _pd=$(dirname "$_gd"); _gn=$(basename "$_gd")
	_cand="$_pd/$_gn.m3u"
	[ -f "$_cand" ] && printf '%s' "$_cand"
}
# 0 (true) if the .m3u lists a disc whose file is missing or 0-byte (busybox-safe scan).
m3u_incomplete() {
	_m="$1"; [ -f "$_m" ] || return 1
	_dir=$(dirname "$_m"); _any=0
	while IFS= read -r _line || [ -n "$_line" ]; do
		[ -n "$_line" ] || continue
		_any=1
		case "$_line" in
			/*) _dp="$_line" ;;
			*)  _dp="$_dir/$_line" ;;
		esac
		[ -s "$_dp" ] || return 0
	done < "$_m"
	[ "$_any" = 0 ] && return 0
	return 1
}
M3U="$(m3u_for "$HOOK_ROM_PATH")"
if [ -n "$M3U" ] && [ -s "$M3U" ] && [ "$STUB_FILLED" != 1 ] && m3u_incomplete "$M3U"; then
	hlog "=== next-disc fetch: $M3U (populated m3u, incomplete disc set) ==="
	rm -f /tmp/dl-progress /tmp/romm-phase 2>/dev/null
	ui_begin "Downloading $GAME…"

	"$RUN" --fetch-next-disc "$M3U" >/dev/null 2>&1 &
	ndpid=$!
	while kill -0 "$ndpid" 2>/dev/null; do
		pct=""; [ -f /tmp/dl-progress ] && pct="$(cat /tmp/dl-progress 2>/dev/null)"
		case "$pct" in
			''|*[!0-9]*)
				ph=""; [ -f /tmp/romm-phase ] && ph="$(cat /tmp/romm-phase 2>/dev/null)"
				[ -n "$ph" ] && ui_set "$ph"
				;;
			*)
				ui_set "Downloading $GAME…  ${pct}%" "$pct"
				;;
		esac
		sleep 0.3
	done
	wait "$ndpid"; ndrc=$?

	if m3u_incomplete "$M3U"; then
		[ "$ndrc" = 6 ] && : > "$PAKDIR/.pairing-expired" 2>/dev/null
		# slog (not hlog): the per-launch disc decision belongs in last-sync.log too,
		# same as the A3 saves line — one log read answers the next field diagnosis.
		slog "discs: next-disc fetch incomplete (rc=$ndrc) action=launch-on-present game=$GAME"
		ui_set "Couldn't fetch the next disc — playing the discs on this card" 0
		sleep 2
	else
		hlog "discs: next disc landed game=$GAME"
		ui_set "Downloaded ✓" 100
		sleep 1
	fi
	ui_stop
fi

# --------------------------------------------------------------------------------------------------
# 2. RESTORE-ON-LAUNCH — the ROM is now present. Offer server saves, if any, via minui-list.
#    (The old SDL lodor-picker was retired; we use the proven minui-list/minui-presenter the rest of
#    the pak already uses — the stock Wifi.pak drives them identically.)
# --------------------------------------------------------------------------------------------------
# No picker available -> launch with the current local save (honest degrade, never block).
[ -x "$LISTBIN" ] || { hlog "minui-list missing -> launching with current save"; exit 0; }

# free show2's framebuffer before minui-list draws.
ui_stop

# Ask the engine which server saves exist (newest-first TSV: <id>\t<date>\t<who>\t<kb>KB[\tCURRENT],
# then a single-field "LOCAL=<none|current|older|unpushed|deleted>" trailer describing the
# on-device save).
# romm-run merges stderr into stdout, so keep only well-formed rows (>=2 tab fields) — the trailer
# is deliberately tab-free so this filter drops it from the row set.
saves_raw="$("$RUN" --list-saves "$HOOK_ROM_PATH" 2>/dev/null)"
lsrc=$?
saves="$(printf '%s\n' "$saves_raw" | awk -F'\t' 'NF>=2')"
localstate="$(printf '%s\n' "$saves_raw" | sed -n 's/^LOCAL=//p' | head -1)"
nsaves=0; [ -n "$saves" ] && nsaves="$(printf '%s\n' "$saves" | wc -l | tr -d ' ')"

# OFFLINE / LIST FAILURE (rc!=0 — exit 3 unreachable, 6 pairing-expired, 2 no Wi-Fi): launch with
# the local save, honestly logged. NEVER claim "no server saves" when we couldn't ask.
if [ "$lsrc" != 0 ]; then
	[ "$lsrc" = 6 ] && : > "$PAKDIR/.pairing-expired" 2>/dev/null
	slog "saves: listed=0 newest=none action=offline (rc=$lsrc) game=$GAME"
	exit 0
fi
# Zero server saves (a REAL empty answer, rc=0): nothing to offer.
if [ -z "$saves" ]; then
	slog "saves: listed=0 newest=none action=silent game=$GAME"
	exit 0
fi

TAB="$(printf '\t')"
newest="$(printf '%s\n' "$saves" | head -1)"
# OVER-PROMPT GUARD (parity item #1), STRICT since task #135: silent ONLY on the engine's
# LOCAL=current trailer, which is judged against the save THIS launch will load and only
# against the NEWEST revision. The row-level CURRENT tag is the Game Manager's display truth
# ("these bytes are on this device" — possibly in the coexist TWIN's save file): gating on it
# silently launched the clean twin into its OLDER save while the (RomM) twin held the newest
# bytes (Smart Pro 2026-07-03 — both Emerald launches logged newest=current action=silent
# while the launched save matched only the OLDER rev 467).
if [ "$localstate" = "current" ]; then
	slog "saves: listed=$nsaves newest=current action=silent local=current game=$GAME"
	exit 0
fi
# DELETED-SAVE TOMBSTONE: the engine's save ledger proves the launched save was deliberately
# DELETED on this device after a sync and the server holds nothing newer — honor the deletion
# silently instead of resurrecting it (the pre-tombstone behavior restored the newest server
# save on every launch). Server Saves in the game menu is the explicit way back — an explicit
# restore always resurrects. (Older engines never emit "deleted"; nothing to degrade.)
if [ "$localstate" = "deleted" ]; then
	slog "saves: listed=$nsaves newest=tombstoned action=silent local=deleted game=$GAME"
	exit 0
fi
# No trailer at all (an older engine build): fall back to the legacy newest-row CURRENT check
# rather than prompting on every launch.
if [ -z "$localstate" ]; then
	case "$newest" in
		*"${TAB}CURRENT")
			slog "saves: listed=$nsaves newest=current action=silent local=no-trailer game=$GAME"
			exit 0 ;;
	esac
fi
newest_who="$(printf '%s\n' "$newest" | cut -f3)"
newest_id="$(printf '%s\n' "$newest" | cut -f1)"

# FIRST PLAY ON THIS DEVICE (A3): server saves exist but there is NO local save (LOCAL=none from
# the engine — content-verified, not guessed). Pull the newest silently: there is nothing on the
# card to lose and nothing to choose between, so a prompt would be pure friction. A restore
# failure degrades to launching fresh (the emulator starts a new save) — logged, never masked.
if [ "$localstate" = "none" ]; then
	if "$RUN" --restore-save "$HOOK_ROM_PATH" "$newest_id" 2>/dev/null | grep -q 'restored=1'; then
		slog "saves: listed=$nsaves newest=foreign action=pulled (save $newest_id from ${newest_who:-unknown}) game=$GAME"
	else
		slog "saves: listed=$nsaves newest=foreign action=offline (silent pull of save $newest_id failed) game=$GAME"
	fi
	exit 0
fi

# Newer/foreign newest + a local save exists (LOCAL=older|unpushed, or an older engine that emits
# no trailer): worth interrupting the launch — the user decides. The restore path preserves the
# current save first (pushed to the timeline, or staged offline), so either answer is lose-proof.
slog "saves: listed=$nsaves newest=foreign action=prompted (from ${newest_who:-unknown}, local=${localstate:-unknown}) game=$GAME"

# Build the minui-list display file + a PARALLEL id file in the SAME line order. Line 1 = continue.
LST="/tmp/lodor-restore-list"; IDS="/tmp/lodor-restore-ids"; OUT="/tmp/lodor-restore-out"
: > "$LST"; : > "$IDS"; rm -f "$OUT"
printf '%s\n' "Continue without restoring" >> "$LST"
printf '%s\n' "__none__" >> "$IDS"
# --list-saves emits "<id>\t<YYYY-MM-DD HH:MM>\t<who>\t<kb>KB[\tCURRENT]" — with IFS=TAB the
# date+time stays one field. CURRENT (when present) marks the revision matching the on-device save.
printf '%s\n' "$saves" | while IFS="$TAB" read -r sid sdate swho ssize scur; do
	label="$sdate  -  $swho  -  $ssize"
	[ "$scur" = "CURRENT" ] && label="$label  (on this device)"
	printf '%s\n' "$label" >> "$LST"
	printf '%s\n' "$sid" >> "$IDS"
done

killall minui-presenter >/dev/null 2>&1 || true
"$LISTBIN" --disable-auto-sleep --file "$LST" --format text \
	--title "Newer save from ${newest_who:-your server} — restore?" --confirm-text "RESTORE" --cancel-text "SKIP" \
	--write-location "$OUT"
lrc=$?
sel="$(cat "$OUT" 2>/dev/null)"
hlog "restore picker rc=$lrc sel=[$sel]"

# Map the selected line text back to its save id by line number (first exact match in the display
# file). Restore ONLY on a real save pick (rc=0). SKIP/B/render-fail or the Continue row -> launch as-is.
chosen_id=""
if [ "$lrc" = 0 ] && [ -n "$sel" ]; then
	ln="$(grep -n -F -x "$sel" "$LST" 2>/dev/null | head -1 | cut -d: -f1)"
	[ -n "$ln" ] && chosen_id="$(sed -n "${ln}p" "$IDS" 2>/dev/null)"
fi

if [ -n "$chosen_id" ] && [ "$chosen_id" != "__none__" ]; then
	killall minui-presenter >/dev/null 2>&1 || true
	[ -x "$PRESBIN" ] && "$PRESBIN" --message "Restoring save…" --timeout -1 >/dev/null 2>&1 &
	if "$RUN" --restore-save "$HOOK_ROM_PATH" "$chosen_id" >/dev/null 2>&1; then
		killall minui-presenter >/dev/null 2>&1 || true
		hlog "restore OK (save $chosen_id)"
		[ -x "$PRESBIN" ] && "$PRESBIN" --message "Restored ✓" --timeout 1 >/dev/null 2>&1
	else
		killall minui-presenter >/dev/null 2>&1 || true
		hlog "restore FAILED (save $chosen_id) -> launching without it"
		[ -x "$PRESBIN" ] && "$PRESBIN" --message "Restore failed — launching without it" --timeout 3 >/dev/null 2>&1
	fi
fi

exit 0
