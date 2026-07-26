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
#   2. Once the ROM is present (just-downloaded or already real) -> the LAUNCH CARD, ALWAYS
#      (task launch-card-v2, ALWAYS-SHOW contract 2026-07-11):
#        - the romm-run --list-saves gate runs ONCE, for its session-setup side effects (Wi-Fi
#          mutex, clock, tier-1 tunnel, device heal) + offline detection + the A3 log line
#        - LOCAL=none first play: pull the newest server save silently FIRST (nothing on the
#          card to lose; a fresh device must not start a blank save), then the card
#        - then lodor-wizard --launch-card --summoned: the FULL card, EVERY launch — including
#          when the gate said offline/pairing-expired (the card is honest offline: local
#          saves/states + "unreachable"). No smart-news silence and no hold-to-summon: the
#          2026-07-11 Smart Pro flash test proved NextUI's busybox has NO `timeout` binary,
#          so the bounded evdev summon probe could never fire on this lane — a card the user
#          cannot summon must simply always appear (his explicit call). Play is one
#          A/B/Start press, so the steady-state cost is a glance.
#        - wizard missing/erroring/timing out -> normal launch, NEVER a blocked/dead screen.
#      EVERY branch logs one reason line to last-sync.log + hook-launch.log:
#        saves: listed=<N> … action=<card|card-offline|pulled|wizard-missing>
#      so the next field diagnosis is one log read — the 2026-07-02 Smart Pro session burned hours
#      because "no server saves" and "server unreachable" were indistinguishable.
#
# HARDWARE NOTE (2026-07-11 Smart Pro flash test): the card RENDERS and plays on TrimUI
# (log: shown=1 action=play rc=0). The fail-safe spine stays the contract regardless: ANY
# wizard problem must still launch the game (the wizard itself always exits 0; no-fb/
# no-input degrade to pass-through).

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

# The launch card renders its OWN framebuffer UI (engine-side ui package) — the old
# minui-list/minui-presenter restore picker is gone from this hook (launch-card-v2).
WIZ="$PAKDIR/lodor-wizard"

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

# Engine progress side-channels live under LODOR_PROGRESS_DIR (default /tmp, device-identical;
# the engine honors the same var). The test harness points it at a per-scenario dir so
# dl-progress/romm-phase can't bleed across scenarios (flaky-gate fix, shell MED-1).
PROGDIR="${LODOR_PROGRESS_DIR:-/tmp}"

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
	rm -f "$PROGDIR/dl-progress" "$PROGDIR/romm-phase" 2>/dev/null
	ui_begin "Downloading $GAME…"

	# Run the engine download in the background so we can stream progress to the screen.
	# Capture stdout (the RESULT line) — multi-disc success can't be read off the passed
	# stub path (see the success check below), so the engine's RESULT is the truth signal.
	dlout="/tmp/lodor-dl-result.$$"
	rm -f "$dlout" 2>/dev/null
	"$RUN" --download "$HOOK_ROM_PATH" >"$dlout" 2>/dev/null &
	dlpid=$!

	# Bridge the engine side-channels -> show2: a numeric $PROGDIR/dl-progress drives the bar + a
	# "Downloading <game>… NN%" line; before the transfer starts (clock/connect) we mirror the
	# engine's human phase label from $PROGDIR/romm-phase. Never fabricate forward progress.
	while kill -0 "$dlpid" 2>/dev/null; do
		pct=""; [ -f "$PROGDIR/dl-progress" ] && pct="$(cat "$PROGDIR/dl-progress" 2>/dev/null)"
		case "$pct" in
			''|*[!0-9]*)
				ph=""; [ -f "$PROGDIR/romm-phase" ] && ph="$(cat "$PROGDIR/romm-phase" 2>/dev/null)"
				[ -n "$ph" ] && ui_set "$ph"
				;;
			*)
				ui_set "Downloading $GAME…  ${pct}%" "$pct"
				;;
		esac
		sleep 0.3
	done
	wait "$dlpid"; dlrc=$?
	dlresult="$(cat "$dlout" 2>/dev/null | grep '^RESULT' | tail -1)"
	rm -f "$dlout" 2>/dev/null

	# HONEST verification — engine RESULT is authoritative, NOT the raw stub byte-size.
	#
	#   SINGLE-FILE: the engine fills IN PLACE at the passed (marked) stub path, so after a
	#     rc=0 downloaded=1 the stub IS the real file — [ -s "$HOOK_ROM_PATH" ] holds and is
	#     kept as the concrete belt.
	#   MULTI-DISC (.m3u, lodor#7 disc-1-first): the engine writes the populated .m3u to the
	#     CANONICAL (unmarked) LocalRomPath + discs into the dot-hidden per-game folder, then
	#     swaps the ✘→✓ marker later at mirror time. The launcher-passed "✘ …m3u" stub is
	#     LEFT 0-byte on purpose — so stat-ing it reads size=0 and the old check declared a
	#     FALSE FAILURE even though disc 1 landed and the game plays (real-device evidence
	#     2026-07-12: RESULT downloaded=1 discs_total=4 discs_present=1, rc=0, but "size=0").
	#     Trust the RESULT: downloaded=1 with discs_present>=1 means LAUNCHABLE.
	# Genuine failures (rc!=0, or downloaded=0 / discs_present=0) still fall through to the
	# honest error path below — this only stops false-positives, never masks a real failure.
	dl_ok=0
	case "$dlresult" in
		*"downloaded=1"*)
			case "$dlresult" in
				*discs_present=*)
					# multi-disc: launchable iff at least one disc is present
					dp="${dlresult##*discs_present=}"; dp="${dp%% *}"
					case "$dp" in ''|*[!0-9]*) dp=0 ;; esac
					[ "$dp" -ge 1 ] && dl_ok=1
					;;
				*)
					# single-file downloaded=1: the in-place fill must have produced bytes
					[ -s "$HOOK_ROM_PATH" ] && dl_ok=1
					;;
			esac
			;;
	esac
	# Fallback (belt): no parseable RESULT (older engine / merged-stderr noise) but rc=0 and
	# the passed path is now non-empty -> single-file success, unchanged pre-fix behavior.
	[ "$dl_ok" = 0 ] && [ "$dlrc" = 0 ] && [ -s "$HOOK_ROM_PATH" ] && dl_ok=1
	hlog "download rc=$dlrc dl_ok=$dl_ok stub_size=$(wc -c < "$HOOK_ROM_PATH" 2>/dev/null) result='${dlresult:-none}'"

	if [ "$dlrc" = 0 ] && [ "$dl_ok" = 1 ]; then
		# ASCII only: show2's font has no ✓ glyph (2026-07-11 flash test rendered tofu).
		ui_set "Downloaded" 100
		sleep 1
		ui_stop
		STUB_FILLED=1
	else
		# Accepted-degradation: a pre-launch hook cannot cancel the launch, so the emulator still
		# opens the (intact, 0-byte) stub and fails fast with its own load error — the engine
		# restores the stub on every failure path, never leaving a corrupt partial file. We never
		# mask the failure; the cause shown maps the engine/romm-run exit honestly (task #120/#124).
		# #2: romm-run's RESERVED wrapper codes are distinct now — 101 pak-broken, 102 Wi-Fi
		# down, 103 busy (another sync holds the mutex — honest wait, never a Wi-Fi claim)
		# (2 kept for a stale pre-#2 wrapper); rc=4 is the engine's ran-but-errored (a server/
		# transfer problem, NOT Wi-Fi); an UNKNOWN rc never claims "check Wi-Fi". #3: every failure
		# splash says the emulator screen that follows WILL fail, so the stub's load error reads
		# as expected instead of as a second mystery.
		case "$dlrc" in
			6) # PAIRING_EXPIRED contract (engine exit 6): flag it for the Tools-menu banner too.
			   : > "$PAKDIR/.pairing-expired" 2>/dev/null
			   ui_error "Pairing expired — open Tools > Lodor to re-pair. The game screen that follows will fail to open — that's expected. Re-pair and launch again." ;;
			102) ui_error "Wi-Fi not connected — enable it in NextUI Settings. The game screen that follows will fail to open — that's expected. Fix the connection and launch again." ;;
			2) ui_error "Lodor hit an internal error — details in last-sync.log. The game screen that follows will fail to open — that's expected. If it keeps happening, re-pair via Tools > Lodor." ;;
			103) ui_error "Another sync is running — try again shortly. The game screen that follows will fail to open — that's expected. Wait a moment and launch again." ;;
			3) ui_error "Couldn't reach your server — check the server or your connection. The game screen that follows will fail to open — that's expected. Fix the connection and launch again." ;;
			# rc=0 here means the engine RAN but reported downloaded=0 / discs_present=0 (a real
			# transfer/server problem: hash mismatch, empty files[], no disc landed) — same class
			# as rc=4, so it gets that honest message rather than a mystery "unknown cause".
			4|0) ui_error "The server had a problem sending this game — try again. The game screen that follows will fail to open — that's expected. Fix the connection and launch again." ;;
			101) ui_error "Lodor is broken on this card — reinstall it from the Pak Store. The game screen that follows will fail to open — that's expected. Reinstall Lodor and launch again." ;;
			*) ui_error "Couldn't download $GAME — unknown cause, try again (details in last-sync.log). The game screen that follows will fail to open — that's expected." ;;
		esac
		hlog "download FAILED (rc=$dlrc result='${dlresult:-none}') — leaving stub; emulator will surface the load error"
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
# Resolve the playlist: the .m3u itself, or the sibling "<Game>.m3u" beside a disc file's
# folder. The per-game disc folder is DOT-HIDDEN (".<Game>/", lodor#7 UX fix); legacy
# non-dot folders and already-dot game names both still map: raw name first, then
# dot-stripped.
m3u_for() {
	case "$1" in
		*.m3u) printf '%s' "$1"; return 0 ;;
	esac
	_gd=$(dirname "$1"); _pd=$(dirname "$_gd"); _gn=$(basename "$_gd")
	_cand="$_pd/$_gn.m3u"
	[ -f "$_cand" ] || _cand="$_pd/${_gn#.}.m3u"
	[ -f "$_cand" ] && printf '%s' "$_cand"
}
# 0 (true) if the engine's OFFLINE completeness gate says this ROM's disc set is incomplete
# (RESULT complete=0). The .m3u is LOCAL-ONLY now — it lists only discs with real bytes, so
# scanning its refs would always read "complete"; the full canonical set lives in the mirror
# manifest and `lodor-sync --check-rom` (filesystem + manifest, pre-config, never the radio)
# is the honest answer. Called DIRECTLY (not via romm-run — no Wi-Fi lock for an offline
# stat). FAIL-OPEN: no binary / unparseable output -> 1 ("complete") -> no fetch, the launch
# proceeds exactly as before.
rom_incomplete() {
	[ -x "$PAKDIR/lodor-sync" ] || return 1
	_ckout=$( cd "$PAKDIR" 2>/dev/null && \
		SDCARD_PATH="$SDCARD" PLATFORM="${PLATFORM:-tg5040}" BASE_PATH="$SDCARD" \
		./lodor-sync --check-rom "$1" 2>/dev/null )
	case "$_ckout" in *"complete=0"*) return 0 ;; esac
	return 1
}
M3U="$(m3u_for "$HOOK_ROM_PATH")"
if [ -n "$M3U" ] && [ -s "$M3U" ] && [ "$STUB_FILLED" != 1 ] && rom_incomplete "$M3U"; then
	hlog "=== next-disc fetch: $M3U (populated m3u, incomplete disc set) ==="
	rm -f "$PROGDIR/dl-progress" "$PROGDIR/romm-phase" 2>/dev/null
	ui_begin "Downloading $GAME…"

	"$RUN" --fetch-next-disc "$M3U" >/dev/null 2>&1 &
	ndpid=$!
	while kill -0 "$ndpid" 2>/dev/null; do
		pct=""; [ -f "$PROGDIR/dl-progress" ] && pct="$(cat "$PROGDIR/dl-progress" 2>/dev/null)"
		case "$pct" in
			''|*[!0-9]*)
				ph=""; [ -f "$PROGDIR/romm-phase" ] && ph="$(cat "$PROGDIR/romm-phase" 2>/dev/null)"
				[ -n "$ph" ] && ui_set "$ph"
				;;
			*)
				ui_set "Downloading $GAME…  ${pct}%" "$pct"
				;;
		esac
		sleep 0.3
	done
	wait "$ndpid"; ndrc=$?

	if rom_incomplete "$M3U"; then
		[ "$ndrc" = 6 ] && : > "$PAKDIR/.pairing-expired" 2>/dev/null
		# slog (not hlog): the per-launch disc decision belongs in last-sync.log too,
		# same as the A3 saves line — one log read answers the next field diagnosis.
		slog "discs: next-disc fetch incomplete (rc=$ndrc) action=launch-on-present game=$GAME"
		ui_set "Couldn't fetch the next disc — playing the discs on this card" 0
		sleep 2
	else
		hlog "discs: next disc landed game=$GAME"
		ui_set "Downloaded" 100
		sleep 1
	fi
	ui_stop
fi

# --------------------------------------------------------------------------------------------------
# 2. LAUNCH CARD, ALWAYS (task launch-card-v2, always-show 2026-07-11) — the ROM is now present.
#    The engine's own per-game card (lodor-wizard --launch-card --summoned): cover-art hero,
#    Play/States/Saves/Manage, D8-compat-dimmed states. It shows on EVERY launch: the old smart
#    (news-only) silence and the hold-to-summon evdev probe are GONE — NextUI's busybox ships no
#    `timeout` binary, so the bounded probe could never fire on this lane (2026-07-11 flash test:
#    "evprobe: no timeout binary -> skip" on every launch), and a card the user cannot summon
#    must simply always appear. The wizard ALWAYS exits 0 and its Play action simply returns —
#    a pre-launch hook cannot cancel the launch and the card never tries to. Fail-safe spine:
#    wizard missing, fb/input open failure, engine probe failure, timeout — ALL degrade to the
#    normal launch, never a blocked/dead screen.
#
#    KEPT FROM THE OLD GATE (the card is NOT a superset of these two):
#      - the romm-run --list-saves gate + A3 log line (romm-run does the session setup — Wi-Fi
#        mutex, clock, tier-1 tunnel, device heal — that the wizard's DIRECT lodor-sync calls
#        skip; and it detects offline/pairing-expired honestly)
#      - the LOCAL=none first-play silent pull (nothing on the card to lose; a fresh device
#        must not start a blank save behind a card whose default action is Play). The card
#        still shows afterwards — its Saves view remains the explicit restore path.
# --------------------------------------------------------------------------------------------------

# wizard_card — run the launch card (FULL card, --summoned), fail-safe. Returns 1 ONLY when the
# wizard binary is missing/not executable (callers log wizard-missing and launch as-is); every
# other outcome — card shown, wizard error, timeout — returns 0 with the rc logged. cd + env
# mirror the contract romm-run gives lodor-sync (config.json loads CWD-relative; the wizard finds
# the engine next to itself, LODOR_BIN as belt-and-suspenders). 90s timeout = muOS-lane parity;
# without a timeout binary — the NextUI reality — it runs unwrapped (the wizard's engine calls
# carry their own deadlines, and the card itself waits on the user by design).
wizard_card() {
	[ -x "$WIZ" ] || { hlog "launch-card: lodor-wizard missing -> skip (fail-safe)"; return 1; }
	ui_stop
	killall minui-presenter >/dev/null 2>&1 || true
	(
		cd "$PAKDIR" 2>/dev/null || exit 125
		export BASE_PATH="$SDCARD" LODOR_PAK_DIR="$PAKDIR" LODOR_BIN="$PAKDIR/lodor-sync"
		export SSL_CERT_FILE="$PAKDIR/certs/ca-certificates.crt"
		# SDL DISPLAY lane (launch-card-v2): NextUI panels present through lodor-fbhelper (raw
		# /dev/fb0 is dead here); input stays the Go EvdevSource. LODOR_HOST_OS=nextui (set at
		# the top of this hook) selects the lane; point the wizard at the bundled helper
		# explicitly (belt — spikeHelperPath also finds it as a sibling of lodor-wizard).
		export LODOR_FBHELPER="$PAKDIR/lodor-fbhelper"
		# The device SDL2 the helper NEEDs (2.30.8) lives in /usr/trimui/lib, like every stock pak.
		export LD_LIBRARY_PATH="/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
		set -- --launch-card --summoned "$HOOK_ROM_PATH"
		if command -v timeout >/dev/null 2>&1; then
			exec timeout 90 "$WIZ" "$@"
		fi
		exec "$WIZ" "$@"
	) >> "$HOOKLOG" 2>&1
	hlog "launch-card rc=$?"
	return 0
}

# free show2's framebuffer before any card draw.
ui_stop

# Reachability gate + A3 decision log, via romm-run (session setup: Wi-Fi mutex, clock, tier-1
# tunnel, device heal). Ask the engine which server saves exist (newest-first TSV:
# <id>\t<date>\t<who>\t<kb>KB[\tCURRENT], then a tab-free "LOCAL=<none|current|older|unpushed|
# deleted>" trailer describing the save THIS launch will load). romm-run merges stderr into
# stdout, so keep only well-formed rows (>=2 tab fields) — the trailer drops out of the row set.
saves_raw="$("$RUN" --list-saves "$HOOK_ROM_PATH" 2>/dev/null)"
lsrc=$?
saves="$(printf '%s\n' "$saves_raw" | awk -F'\t' 'NF>=2')"
localstate="$(printf '%s\n' "$saves_raw" | sed -n 's/^LOCAL=//p' | head -1)"
nsaves=0; [ -n "$saves" ] && nsaves="$(printf '%s\n' "$saves" | wc -l | tr -d ' ')"

# OFFLINE / LIST FAILURE (rc!=0 — exit 3 unreachable, 6 pairing-expired, 2/102 no Wi-Fi): the
# card STILL shows (always-show): it is honest offline — local saves/states + "unreachable" —
# and the user always gets the menu. NEVER claim "no server saves" when we couldn't ask; the
# A3 line records the gate verdict so the card's own probe failures read as confirmation, not
# a mystery. Wizard missing -> logged, normal launch.
if [ "$lsrc" != 0 ]; then
	[ "$lsrc" = 6 ] && : > "$PAKDIR/.pairing-expired" 2>/dev/null
	slog "saves: listed=0 newest=none action=card-offline (rc=$lsrc) game=$GAME"
	if ! wizard_card; then
		slog "saves: listed=0 newest=none action=wizard-missing (launching as-is) game=$GAME"
	fi
	exit 0
fi

# FIRST PLAY ON THIS DEVICE (A3): server saves exist but there is NO local save (LOCAL=none from
# the engine — content-verified, not guessed). Pull the newest silently BEFORE the card: there is
# nothing on the card to lose and nothing to choose between, and the card's default action is
# Play — a blank first save must never race a one-press launch. A pull failure degrades to
# launching fresh — logged, never masked. The card still shows below (always-show); its Saves
# view is the explicit path to any other revision.
if [ "$localstate" = "none" ] && [ -n "$saves" ]; then
	newest="$(printf '%s\n' "$saves" | head -1)"
	newest_id="$(printf '%s\n' "$newest" | cut -f1)"
	newest_who="$(printf '%s\n' "$newest" | cut -f3)"
	if "$RUN" --restore-save "$HOOK_ROM_PATH" "$newest_id" 2>/dev/null | grep -q 'restored=1'; then
		slog "saves: listed=$nsaves newest=foreign action=pulled (save $newest_id from ${newest_who:-unknown}) game=$GAME"
	else
		slog "saves: listed=$nsaves newest=foreign action=pull-failed (silent pull of save $newest_id failed; launching fresh) game=$GAME"
	fi
fi

# THE CARD, every launch. The engine owns every decision on it (STRICT #135 LOCAL=older lineage,
# deleted-save tombstones, the twin/CURRENT-tag trap, D8 state compat) — this hook renders
# nothing and decides nothing. Play is one press; States/Saves/Manage are one press away.
slog "saves: listed=$nsaves local=${localstate:-unknown} action=card game=$GAME"
if ! wizard_card; then
	slog "saves: listed=$nsaves local=${localstate:-unknown} action=wizard-missing (launching as-is) game=$GAME"
fi

exit 0
