#!/bin/sh
# Lodor (NextUI Tool, tg5040 / tg5050) — SELF-ONBOARDING sync layer for the Lodor RomM engine.
#
# ONE pak, two states (this pak replaces the old split of "Lodor.pak" + "Lodor Setup.pak"):
#   - NOT configured yet -> run the on-device onboarding WIZARD (server URL -> pairing code ->
#     device name), shelling the SAME arm64 engine (lodor-sync) via --set-server / --pair /
#     --register-device to write config.json into the pak dir (Tools/<plat>/Lodor.pak). No JSON editing.
#   - Already configured -> the normal CLIENT: first-run hook self-install + background sync daemon,
#     then the Tools menu (Sync now / Pending saves / Refresh library / Game Manager / Search
#     library / Download queue / Download BIOS / Recent activity / Switch user / Box art /
#     RomM games layout / Setup-Re-pair).
# The client menu keeps a "Setup / Re-pair" entry so a mis-paired or server-changed device can re-run
# the wizard — the onboarding flow is never stranded behind a deleted pak.
#
# The interactive menu + keyboard + status messages are drawn by minui-list / minui-keyboard /
# minui-presenter (josegonzalez's battle-tested MinUI/NextUI tools — the stock Wifi.pak uses the exact
# same binaries). Each action shells the Lodor engine (bin/romm-run -> lodor-sync). HOST RENDERING
# ONLY — all RomM logic lives in the engine; NextUI is NOT forked. This Tool RIDES NextUI's Wi-Fi
# (NextUI owns the radio); the engine owns all RomM logic.
#
# Honesty rules (feedback_no_fake_ui_state): never show a step done until it is verified done; errors
# are persistent + readable with a cause; if a presenter is missing we degrade honestly to a one-shot
# Sync now, never silently die. Every wizard step shows the engine's REAL RESULT / exit code.
set -u
PAKDIR="$(dirname "$0")"
cd "$PAKDIR" || exit 1

# NextUI's boot.sh exports these for its own SDL/msettings binaries. Re-assert them so minui-list /
# minui-keyboard / minui-presenter resolve /usr/trimui/lib (belt-and-suspenders; stock paks rely on
# plain inheritance).
export LD_LIBRARY_PATH="/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export PATH="/usr/trimui/bin:${PATH:-}"

LOG="$PAKDIR/last-sync.log"
: > "$LOG"
. "$PAKDIR/lib/romm-sync-lib.sh"

# TEST HOOK (inert in production — LODOR_TEST_LIB is never set on-device): the off-device wizard
# simulator (integrations/nextui/test/) sources its overrides for the hardware-facing helpers
# (wlan0 probes, tailscale daemon control, resolv/clock writers) HERE, after the real lib, so
# every OTHER line of this script runs unmodified under test.
if [ -n "${LODOR_TEST_LIB:-}" ] && [ -f "$LODOR_TEST_LIB" ]; then . "$LODOR_TEST_LIB"; fi

log() { echo "$(date +'%F %T') $1" >> "$LOG"; }

# --------------------------------------------------------------------------------------------------
# PAIRING-EXPIRED (task #124). Engine contract (shipped): a revoked/expired token exits 6 with a
# final stdout line PAIRING_EXPIRED (and --validate reports pairing_expired=1). The pak maps that to
# ONE honest, actionable state: a flag file beside config.json that (a) puts a re-pair banner at the
# TOP of the client menu and (b) turns every failure message into "run Setup / Re-pair" instead of a
# generic sync error. The flag is cleared by the first SUCCESSFUL network engine call (rc=0 proves
# the token works — including the re-pair itself). The hooks set the same flag (same path) so a
# launch-time detection surfaces in the menu too.
# --------------------------------------------------------------------------------------------------
PAIR_FLAG="$LODOR_CFG_DIR/.pairing-expired"
note_net_rc() {  # <rc of a NETWORK engine call> — set/clear the pairing-expired flag honestly
	case "${1:-}" in
		6) : > "$PAIR_FLAG" 2>/dev/null; log "pairing expired (engine rc=6) - flagged for re-pair" ;;
		0) [ -f "$PAIR_FLAG" ] && { rm -f "$PAIR_FLAG" 2>/dev/null; log "pairing OK again - flag cleared"; } ;;
	esac
	return 0
}

# --------------------------------------------------------------------------------------------------
# minui-list / minui-keyboard / minui-presenter UI (proven on tg5040 — the stock Wifi.pak drives them
# identically).
#   Contract (learned from Wifi.pak launch.sh):
#     minui-list  --file <items> --format text --title <t> --confirm-text <c> --cancel-text <x>
#                 --write-location <out> --disable-auto-sleep
#         -> selected line text written to <out>; exit 0=picked, 2=back(B), 3=menu, other=render fail.
#     minui-keyboard --title <t> --initial-value <v> --write-location <out>
#         -> typed text written to <out>; exit 0=confirmed, 2=back(B), 3=menu, other=render fail.
#     minui-presenter --message <msg> --timeout <secs>   (secs=-1 => persist until killed)
#         -> draws a centered message; killall before each new one (Wifi.pak's show_message pattern).
# --------------------------------------------------------------------------------------------------
BINPLAT="${PLATFORM:-tg5040}"
[ "$BINPLAT" = "tg3040" ] && BINPLAT="tg5040"
LISTBIN="$PAKDIR/bin/$BINPLAT/minui-list"
PRESBIN="$PAKDIR/bin/$BINPLAT/minui-presenter"
KBBIN="$PAKDIR/bin/$BINPLAT/minui-keyboard"
MENU_OUT="/tmp/lodor-menu-out"
MENU_LST="/tmp/lodor-menu-list"

# --------------------------------------------------------------------------------------------------
# TAILSCALE (tier-1) — QR sign-in + status, tg5040 / tg5050 only. Host rendering only: the tunnel
# bring-up + status live in tailscale-lib.sh (sourced via romm-sync-lib.sh); the engine owns all RomM
# logic and routes through the SOCKS5 proxy once config.json is marked tier-1. NextUI is NOT forked —
# the QR is drawn by the bundled standalone SDL helper (bin/<plat>/lodor-qr), not the launcher.
# --------------------------------------------------------------------------------------------------
QRBIN="$PAKDIR/bin/$BINPLAT/lodor-qr"
# MUST NOT collide with the lib's TS_STATEDIR (/tmp/lodor-ts-state) — tailscaled creates a
# DIRECTORY there at bring-up, and `: > <dir>` is a redirect error on a special builtin, which
# per POSIX EXITS THE SHELL. That was the silent onboarding death on every Brick boot
# (proved by pak-trace 2026-07-02 09:15: "can't create /tmp/lodor-ts-state: Is a directory").
TS_STATE_FILE="/tmp/lodor-ts-status.txt"

# ts_available — is the Tailscale path usable on THIS device? tg5040/tg5050 (both 1 GB arm64) with the
# daemon + CLI bundled. When false the wizard/menu hide every Tailscale row (no dead options).
ts_available() {
	command -v tailscale_up_interactive >/dev/null 2>&1 || return 1
	case "$PLAT" in tg5040|tg5050|tg3040) : ;; *) return 1 ;; esac
	[ -x "$TS_BIN_DIR/tailscaled" ] && [ -x "$TS_BIN_DIR/tailscale" ]
}

# ts_qr_text_fallback <url> — NO-QR degraded path: restore a clean screen, show the raw login
# URL, and poll the REAL BackendState until connected or ~120s. Used when lodor-qr is MISSING or
# FAILED TO RENDER (render-failure exit / crash), so onboarding still COMPLETES from the printed
# URL even when the QR never paints. Honest throughout (no fake progress). The bg status writer is
# already running; this only reads status. Returns 0 connected, 1 otherwise.
ts_qr_text_fallback() {
	killall lodor-qr        >/dev/null 2>&1 || true   # reap any stray/hung helper
	killall minui-presenter >/dev/null 2>&1 || true   # clean display before we draw the URL
	ui_msg "Sign in at: $1   (waiting for sign-in...)"
	_n=0
	while [ "$_n" -lt 60 ]; do
		[ "$(tailscale_status 2>/dev/null)" = connected ] && { ui_clear; return 0; }
		sleep 2; _n=$((_n + 1))
	done
	ui_clear
	return 1
}

# ts_show_qr <url> — draw the QR + raw URL and block until the node is Running (connected), the user
# cancels, or ~120s elapses. Returns 0 connected, 1 otherwise. A background writer keeps TS_STATE_FILE
# honest (real BackendState, never fabricated); the SDL helper renders it.
#
# RESILIENCE (the point of this function): lodor-qr's exit code is trusted to disambiguate —
#   0            = connected -> success
#   2 (cancel)   = user backed out       -> ABORT onboarding (return 1, NO fallback)
#   3 (timeout)  = timed out             -> ABORT onboarding (return 1, NO fallback)
#   * (4/139/... )= render/init failure or crash -> the QR never painted, so FALL THROUGH to the
#                  text-URL + status poll and let sign-in complete anyway.
# If the helper binary is missing entirely we take the same text-URL fallback.
ts_show_qr() {
	_u="$1"
	# `true` not `:` — a redirect error on the special builtin `:` exits the whole shell (POSIX);
	# on `true` (regular builtin) it just fails. rm -rf clears any stale dir at the path first.
	rm -rf "$TS_STATE_FILE" 2>/dev/null || true
	true > "$TS_STATE_FILE" 2>/dev/null || true
	( while :; do tailscale_status > "$TS_STATE_FILE" 2>/dev/null; sleep 1; done ) &
	_wpid=$!
	_qrc=1
	if [ -x "$QRBIN" ]; then
		killall minui-presenter >/dev/null 2>&1 || true
		log "ts: rendering QR"
		"$QRBIN" --url "$_u" --statefile "$TS_STATE_FILE" --ready connected \
			--title "Sign in to Tailscale" --timeout 120 >"$PAKDIR/qr-stderr.log" 2>&1
		_ec=$?
		case "$_ec" in
			0) _qrc=0 ;;                                  # connected
			2) _qrc=1 ;;                                  # user cancelled -> abort, no fallback
			3) _qrc=1 ;;                                  # timed out      -> abort, no fallback
			*)                                            # render failure / crash -> text fallback
				log "lodor-qr render failure (exit $_ec) - falling back to text URL"
				ts_qr_text_fallback "$_u"; _qrc=$?
				;;
		esac
	else
		log "lodor-qr missing - using text URL fallback"
		ts_qr_text_fallback "$_u"; _qrc=$?
	fi
	kill "$_wpid" >/dev/null 2>&1
	return "$_qrc"
}

# ts_onboard — full interactive QR sign-in: Wi-Fi -> userspace tailscaled + interactive `up` (NO
# authkey) -> scrape login URL -> QR -> poll to Running. Returns 0 on a connected node, 1 otherwise.
# On success the daemon is LEFT UP so the pairing steps route through the tunnel. Honest throughout.
ts_onboard() {
	require_wifi || return 1
	ui_msg "Starting Tailscale sign-in..."
	# CRITICAL: do NOT call tailscale_up_interactive inside $(...). The function spawns tailscaled
	# and a backgrounded `tailscale up` — on busybox ash, children of a command-substitution subshell
	# can hold the substitution pipe open and the $() NEVER RETURNS (the pak froze at "Starting
	# Tailscale sign-in..." on both 2026-07-02 Brick boots, right after "login URL captured").
	# Redirecting to a FILE has no such wait: the call returns when the function returns.
	_urlf="/tmp/lodor-ts-url.$$"
	tailscale_up_interactive > "$_urlf" 2>/dev/null
	# literal char set, NOT a class: this busybox tr treats '[:space:]' as the literal chars
	# [ : s p a c e ] and shredded the URL to "htt//login.till.om/..." (pak-trace 09:15).
	_url="$(head -1 "$_urlf" 2>/dev/null | tr -d ' \t\r')"
	rm -f "$_urlf"
	log "ts: bring-up returned, url_len=${#_url}"
	ui_clear
	if [ -z "$_url" ]; then
		# empty URL = already signed in (persisted state) OR bring-up failed. Disambiguate by status.
		if [ "$(tailscale_status 2>/dev/null)" = connected ]; then
			ui_msg_timed "Tailscale already signed in." 3
			return 0
		fi
		ui_error_ack "Couldn't start Tailscale sign-in. Check Wi-Fi, or choose Home / public URL. Still stuck? Menu > Tailscale: Reset & forget."
		return 1
	fi
	if ts_show_qr "$_url"; then
		ui_msg_timed "Signed in to Tailscale." 2
		return 0
	fi
	# cancel / timeout: stop the pending interactive `up` + daemon so a retry starts clean.
	[ -f "$TS_STATEDIR/up.pid" ] && kill "$(cat "$TS_STATEDIR/up.pid" 2>/dev/null)" >/dev/null 2>&1
	tailscale_down >/dev/null 2>&1
	ui_error_ack "Tailscale sign-in didn't complete. Try again, or use Home / public URL."
	return 1
}

# do_ts_status / do_ts_reset — client-menu Tailscale maintenance (mirrors the LodorOS Tailscale.pak).
do_ts_status() {
	if [ "$(tailscale_status 2>/dev/null)" = connected ]; then
		_tip="$(tailscale_ip 2>/dev/null)"
		ui_msg_timed "Tailscale: CONNECTED${_tip:+  $_tip}" 5
	else
		ui_msg_timed "Tailscale: not connected. Re-onboard via Setup / Re-pair > Tailscale." 5
	fi
}
do_ts_reset() {
	ui_msg "Resetting Tailscale..."
	ts_reset >/dev/null 2>&1
	ui_msg_timed "Tailscale reset. Re-onboard via Setup / Re-pair > Tailscale." 5
}
# do_ts_reconnect (task #134) — restart tailscaled from the PERSISTED login. No QR, no
# re-auth, RomM pairing untouched; only Reset & forget wipes the sign-in. The persistent
# ui_msg is TRUE while shown — the reconnect runs underneath it (worst case ~45s).
do_ts_reconnect() {
	ui_msg "Reconnecting Tailscale..."
	_tsr="$(tailscale_reconnect 2>/dev/null)"
	case "$_tsr" in
		connected:*) ui_msg_timed "Reconnected (${_tsr#connected:})" 5 ;;
		connected)   ui_msg_timed "Reconnected." 5 ;;
		no-login)    ui_msg_timed "No saved Tailscale sign-in. Re-onboard via Setup / Re-pair > Tailscale." 5 ;;
		not-capable|no-binary) ui_msg_timed "Tailscale is not available on this device." 5 ;;
		*)           ui_error_ack "Couldn't reconnect - Tailscale didn't reach Running. Check Wi-Fi (details: tailscaled.log)" ;;
	esac
}

ui_msg() {        # persistent message until replaced/cleared
	killall minui-presenter >/dev/null 2>&1 || true
	[ -x "$PRESBIN" ] && "$PRESBIN" --message "$1" --timeout -1 >/dev/null 2>&1 &
	log "msg: $1"
}
ui_msg_timed() {  # blocking message for N seconds (default 3)
	killall minui-presenter >/dev/null 2>&1 || true
	log "msg: $1"
	[ -x "$PRESBIN" ] && "$PRESBIN" --message "$1" --timeout "${2:-3}" >/dev/null 2>&1
}
ui_clear() { killall minui-presenter >/dev/null 2>&1 || true; }

# ui_error_ack <message> (#6) — FAILURES are dismissable, not timed flashes: draw the message as a
# one-row read-only minui-list (any button exits — the gm_details pattern) so slow readers aren't
# rushed and fast readers aren't stuck waiting. Logged with an err: prefix (greppable in
# last-sync.log). Falls back to a timed message only when the list renderer is missing or fails to
# draw. SUCCESSES stay timed (ui_msg_timed) — only failure paths route here.
ui_error_ack() {
	log "err: $1"
	if [ -x "$LISTBIN" ]; then
		ERR_LST="/tmp/lodor-error-list"
		printf '%s\n' "$1" > "$ERR_LST"
		killall minui-presenter >/dev/null 2>&1 || true
		"$LISTBIN" --disable-auto-sleep --file "$ERR_LST" --format text \
			--title "Lodor - problem" --confirm-text "OK" --cancel-text "BACK" \
			--write-location /tmp/lodor-error-out >/dev/null 2>&1
		case $? in 0|2|3) return 0 ;; esac   # dismissed; a render failure falls through
	fi
	killall minui-presenter >/dev/null 2>&1 || true
	[ -x "$PRESBIN" ] && "$PRESBIN" --message "$1" --timeout 4 >/dev/null 2>&1
	return 0
}

# show2.elf live-progress presenter (#1): the SAME show2 driver the fetch hook uses (one bridge,
# not two divergent copies) — sourced so the long mirror passes (Refresh library / first seed /
# wizard seed) can stream the engine's REAL side-channel progress instead of a static
# minutes-long message.
SHOW2_LOGO="$PAKDIR/res/lodor.png"
SHOW2_LOGFN="log"
. "$PAKDIR/lib/show2-lib.sh" 2>/dev/null
# Degrade honestly if the lib is missing (old/partial card): a persistent presenter message
# stands in for the live bar — never die over cosmetics.
command -v ui_begin >/dev/null 2>&1 || {
	ui_begin() { ui_msg "$1"; }
	ui_set() { :; }
	ui_stop() { ui_clear; }
}

# settings.conf lives beside config.json in the pak dir (LODOR_CFG_DIR, from the lib; #30) so the
# engine reads the toggle CWD-relative there. Migrate any settings.conf left in the old shared home.
lodor_migrate_cfg
SETTINGS="$LODOR_CFG_DIR/settings.conf"
SEED_SENTINEL="$PAKDIR/.library-seeded"
RUN="$PAKDIR/bin/romm-run"

# --------------------------------------------------------------------------------------------------
# GAME MANAGER ROOT ENTRY (task #128; moved to the BOTTOM of the root library, task #134 — browsing/
# launching games is the primary UX, the Game Manager is a utility). Zero launcher fork, purely
# through data NextUI already renders:
#   Roms/Game Manager (LODORGM)/             <- getRoot() lists Roms/* dirs at root; the "(LODORGM)"
#                                               tag is stripped by getDisplayName, so the pre-alias
#                                               row reads "Game Manager".
#     Open Game Manager.gm                   <- ONE non-empty entry file (hasRoms needs >=1 file; the
#                                               fetch hook's 0-byte stub check must pass over it).
#     Game Manager (LODORGM).m3u             <- makes the folder an AUTO-LAUNCH dir: Entry_open ->
#                                               openDirectory(path, auto_launch=1) finds <dirname>.m3u
#                                               -> getFirstDisc -> openRom, so ONE press on the root
#                                               row launches the Game Manager (no folder hop).
#   Emus/<plat>/LODORGM.pak/launch.sh        <- hasEmu("LODORGM") makes the folder visible; NextUI
#                                               launches it as an Emu pak; it exec's THIS script with
#                                               --game-manager, so both entries run the SAME code.
#   Roms/map.txt alias line                  <- the BOTTOM sort: NextUI aliases root folder names via
#       "Game Manager (LODORGM)\t<NBSP>Game Manager"
#                                               (nextui.c getRoms) and RESORTS BY THE ALIAS, so the
#                                               alias is both display AND sort key. trimSortingMeta
#                                               only strips digit prefixes (always TOP), so the only
#                                               clean bottom anchor is a leading U+00A0 NBSP: its
#                                               first byte 0xC2 sorts after every ASCII letter
#                                               (strcasecmp is bytewise) and both shipped NextUI
#                                               fonts render NBSP as a blank space-width glyph — the
#                                               row reads "Game Manager". map.txt lost/absent =>
#                                               graceful degrade: clean name, sorted under G.
# All of it ships statically in assemble.sh (except map.txt — merged on device, never clobbered) AND
# is re-created here on first run if absent (same self-install pattern as the hooks) so an engine/
# pak-only update onto an older card heals itself. The heal also MIGRATES the pre-#134 top-sorted
# "0) Game Manager (LODORGM)" folder off the card.
GM_TAG="LODORGM"
GM_DIRNAME="Game Manager ($GM_TAG)"
GM_DIRNAME_OLD="0) Game Manager ($GM_TAG)"
GM_ENTRY="Open Game Manager.gm"
GM_MODE=0
case "${1:-}" in --game-manager) GM_MODE=1 ;; esac

# CONTINUE ROOT ENTRY (task #134): the one-press cross-device resume row at the TOP of the
# library — same zero-fork trick as the Game Manager ("0) " digit prefix sorts FIRST and
# renders "Continue"; the <dirname>.m3u auto-launches; Emus/<plat>/LODORCT.pak is the
# RESUME DISPATCHER — see ctpak/launch.sh). The engine refreshes its data (continue-head.txt
# + the optional "0) Continue: <Game>" map.txt label) on every sync.
CT_TAG="LODORCT"
CT_DIRNAME="0) Continue ($CT_TAG)"
CT_ENTRY="Continue.ct"

# gm_root_selfheal — install/repair the root-entry artifacts. Emus pak = CODE -> cmp-refreshed to
# this pak's copy; Roms folder = static DATA -> cmp-healed (absent or byte-drifted -> rewritten).
# Never fatal: the Tools-menu Game Manager keeps working even if the card refuses these writes.
# Needs NOTHING but the SD card (no config, no engine, no network), so it runs:
#   1. here, at EVERY pak open, BEFORE the onboarding gate (task #131 — the 0.9.1-beta Smart Pro
#      test showed the root row missing while Tools -> Lodor worked: the heal used to sit AFTER the
#      onboarding gate, so a partial card update + a cancelled/incomplete wizard session left
#      Roms/"0) Game Manager (LODORGM)" and/or Emus/<plat>/LODORGM.pak absent for every root scan.
#      NextUI's scan itself is proven clean for these exact names — test/rootscan compiles the real
#      hide/getEmuName/hasEmu/hasRoms/getRoms from the NextUI source and shows the row surviving);
#   2. from hooks/boot.d/10-lodor.sh, which MinUI.pak runs BEFORE the first nextui.elf of every
#      boot — so once hooks are wired the artifacts provably exist before every root scan.
gm_root_selfheal() {
	GM_SRC="$PAKDIR/gmpak"
	[ -d "$GM_SRC" ] || return 0
	GM_EMUDST="$SDCARD/Emus/$PLAT/$GM_TAG.pak"
	if ! cmp -s "$GM_SRC/launch.sh" "$GM_EMUDST/launch.sh" 2>/dev/null; then
		mkdir -p "$GM_EMUDST" 2>/dev/null
		cp -f "$GM_SRC/launch.sh" "$GM_EMUDST/launch.sh" 2>/dev/null && chmod +x "$GM_EMUDST/launch.sh" 2>/dev/null
		if cmp -s "$GM_SRC/launch.sh" "$GM_EMUDST/launch.sh" 2>/dev/null; then
			log "gm root entry: Emus/$PLAT/$GM_TAG.pak installed/refreshed"
		else
			log "WARN: gm root entry: could not install Emus/$PLAT/$GM_TAG.pak - root row will stay hidden (hasEmu)"
		fi
	fi
	GM_ROMDST="$SDCARD/Roms/$GM_DIRNAME"
	for _gmf in "$GM_ENTRY" "$GM_DIRNAME.m3u"; do
		if ! cmp -s "$GM_SRC/roms/$_gmf" "$GM_ROMDST/$_gmf" 2>/dev/null; then
			mkdir -p "$GM_ROMDST" 2>/dev/null
			cp -f "$GM_SRC/roms/$_gmf" "$GM_ROMDST/$_gmf" 2>/dev/null
			if cmp -s "$GM_SRC/roms/$_gmf" "$GM_ROMDST/$_gmf" 2>/dev/null; then
				log "gm root entry: Roms/$GM_DIRNAME/$_gmf installed/healed"
			else
				log "WARN: gm root entry: could not write Roms/$GM_DIRNAME/$_gmf"
			fi
		fi
	done
	# MIGRATION (task #134): retire the pre-#134 top-sorted folder. Entirely Lodor-owned data
	# (entry + m3u) — safe to remove wholesale, but only once the NEW folder verifiably exists
	# so a failed heal never leaves a card with NO Game Manager root row at all.
	if [ -d "$SDCARD/Roms/$GM_DIRNAME_OLD" ] && [ -f "$GM_ROMDST/$GM_ENTRY" ]; then
		rm -rf "$SDCARD/Roms/$GM_DIRNAME_OLD" 2>/dev/null
		if [ -d "$SDCARD/Roms/$GM_DIRNAME_OLD" ]; then
			log "WARN: gm root entry: could not remove legacy Roms/$GM_DIRNAME_OLD (two GM rows will show)"
		else
			log "gm root entry: migrated - legacy Roms/$GM_DIRNAME_OLD removed"
		fi
	fi
	root_map_selfheal
	return 0
}

# root_map_selfheal — ensure the Roms/map.txt BOTTOM-SORT alias line for the Game Manager (see the
# block comment above). MERGE, never clobber: every non-GM line (user aliases, the engine-owned
# "0) Continue (LODORCT)" label) is preserved verbatim; tmp+rename keeps FAT32 writes atomic.
root_map_selfheal() {
	_mfile="$SDCARD/Roms/map.txt"
	_mtab="$(printf '\t')"
	# U+00A0 NBSP prefix: first byte 0xC2 > every ASCII letter => sorts LAST; renders as a blank.
	_mline="$(printf 'Game Manager (%s)\t\302\240Game Manager' "$GM_TAG")"
	grep -qF "$_mline" "$_mfile" 2>/dev/null && return 0
	_mtmp="$_mfile.tmp.$$"
	{ [ -f "$_mfile" ] && grep -v "^Game Manager ($GM_TAG)$_mtab" "$_mfile" 2>/dev/null
	  printf '%s\n' "$_mline"; } > "$_mtmp" 2>/dev/null && mv -f "$_mtmp" "$_mfile" 2>/dev/null
	rm -f "$_mtmp" 2>/dev/null
	if grep -qF "$_mline" "$_mfile" 2>/dev/null; then
		log "gm root entry: Roms/map.txt bottom-sort alias installed"
	else
		log "WARN: gm root entry: could not write Roms/map.txt (GM will sort under G, display stays clean)"
	fi
}
gm_root_selfheal

# ct_root_selfheal — the Continue root entry's install/repair, the exact gm_root_selfheal
# pattern (Emus pak = CODE cmp-refresh; Roms folder = DATA cmp-heal; never fatal).
ct_root_selfheal() {
	CT_SRC="$PAKDIR/ctpak"
	[ -d "$CT_SRC" ] || return 0
	CT_EMUDST="$SDCARD/Emus/$PLAT/$CT_TAG.pak"
	if ! cmp -s "$CT_SRC/launch.sh" "$CT_EMUDST/launch.sh" 2>/dev/null; then
		mkdir -p "$CT_EMUDST" 2>/dev/null
		cp -f "$CT_SRC/launch.sh" "$CT_EMUDST/launch.sh" 2>/dev/null && chmod +x "$CT_EMUDST/launch.sh" 2>/dev/null
		if cmp -s "$CT_SRC/launch.sh" "$CT_EMUDST/launch.sh" 2>/dev/null; then
			log "ct root entry: Emus/$PLAT/$CT_TAG.pak installed/refreshed"
		else
			log "WARN: ct root entry: could not install Emus/$PLAT/$CT_TAG.pak - Continue row will stay hidden (hasEmu)"
		fi
	fi
	CT_ROMDST="$SDCARD/Roms/$CT_DIRNAME"
	for _ctf in "$CT_ENTRY" "$CT_DIRNAME.m3u"; do
		if ! cmp -s "$CT_SRC/roms/$_ctf" "$CT_ROMDST/$_ctf" 2>/dev/null; then
			mkdir -p "$CT_ROMDST" 2>/dev/null
			cp -f "$CT_SRC/roms/$_ctf" "$CT_ROMDST/$_ctf" 2>/dev/null
			if cmp -s "$CT_SRC/roms/$_ctf" "$CT_ROMDST/$_ctf" 2>/dev/null; then
				log "ct root entry: Roms/$CT_DIRNAME/$_ctf installed/healed"
			else
				log "WARN: ct root entry: could not write Roms/$CT_DIRNAME/$_ctf"
			fi
		fi
	done
	return 0
}
ct_root_selfheal

# scrub_recents (B3) — remove the GM/Continue dispatcher dummy rows from NextUI's Recently
# Played / Game Switcher list (they are affordances, not games; the Continue dummy in the
# switcher is the prime blacked-row suspect). Runs in launcher-dead windows only (we ARE the
# "emulator"/Tool). Real rows + aliases preserved verbatim; tmp+rename atomic. The engine's
# recents-merge drops these rows too, so a sync can never re-inject them.
scrub_recents() {
	_rf="$SDCARD/.userdata/shared/.minui/recent.txt"
	[ -f "$_rf" ] || return 0
	grep -qE '\((LODORGM|LODORCT)\)/' "$_rf" 2>/dev/null || return 0
	_rt="$_rf.tmp.$$"
	grep -vE '\((LODORGM|LODORCT)\)/' "$_rf" > "$_rt" 2>/dev/null && mv -f "$_rt" "$_rf" 2>/dev/null
	rm -f "$_rt" 2>/dev/null
	return 0
}

get_mirror_mode() {
	_mm=
	[ -f "$SETTINGS" ] && _mm="$(sed -n 's/^mirror_mode=//p' "$SETTINGS" 2>/dev/null | head -1)"
	# Report the mode HONESTLY (own|separate|merge). Absent/unknown defaults to MERGE —
	# the engine's NextUI default since C2 (2026-07-02) — and ensure_mirror_mode makes the
	# value explicit on every configured card anyway (fresh cards silently, upgrade cards
	# via the one-time consent prompt), so the default label is a brief first-run state,
	# never a standing lie (the pre-C2 bug: displayed "separate" while the engine ran own).
	case "$_mm" in own) echo own ;; separate) echo separate ;; *) echo merge ;; esac
}
# set_setting <key> <value> — rewrite ONE key=value line in settings.conf, preserving every other
# line (tmp + rename so a died write never truncates the file). Verifies the write landed.
set_setting() {
	_sk="$1"; _sv="$2"; _tmp="$SETTINGS.tmp.$$"
	{ [ -f "$SETTINGS" ] && grep -v "^$_sk=" "$SETTINGS" 2>/dev/null; echo "$_sk=$_sv"; } > "$_tmp" 2>/dev/null \
		&& mv -f "$_tmp" "$SETTINGS" 2>/dev/null
	rm -f "$_tmp" 2>/dev/null
	[ "$(sed -n "s/^$_sk=//p" "$SETTINGS" 2>/dev/null | head -1)" = "$_sv" ]
}
set_mirror_mode() {
	set_setting mirror_mode "$1" && [ "$(get_mirror_mode)" = "$1" ]
}

# ensure_mirror_mode (C2) — make the coexist mode EXPLICIT exactly once per card. Mode flips are
# PROMPT-ONLY in the engine (a defaulted mode never migrates/restructures a card), so this is the
# consent point:
#   - settings.conf already carries mirror_mode -> nothing to do (the standing state).
#   - No separate-era residue on the card (no "… RomM (TAG)" folders, no "* (RomM).*" files) ->
#     silently write merge: for a fresh card AND for the pre-C2 de-facto-own cards this is a
#     ZERO-RENAME upgrade (merge and own share names) that only adds the dedup/manifest safety.
#   - Residue found (a true separate-era card, or the field twin mess) -> ask ONCE: choosing merge
#     authorizes the engine's migration (twin cleanup, save lineages pushed first) on the next
#     Refresh; choosing separate keeps the quarantine layout. B/cancel decides nothing and asks
#     again next open (rare — only residue cards ever see the prompt).
ensure_mirror_mode() {
	[ -n "$(sed -n 's/^mirror_mode=//p' "$SETTINGS" 2>/dev/null | head -1)" ] && return 0
	_emm_residue=0
	for _emm_d in "$SDCARD/Roms/"*" RomM ("*")"; do
		[ -d "$_emm_d" ] && { _emm_residue=1; break; }
	done
	if [ "$_emm_residue" = 0 ] && [ -d "$SDCARD/Roms" ]; then
		if find "$SDCARD/Roms" -maxdepth 2 -name "* (RomM).*" 2>/dev/null | head -1 | grep -q .; then
			_emm_residue=1
		fi
	fi
	if [ "$_emm_residue" = 0 ]; then
		set_mirror_mode merge && log "coexist: mirror_mode=merge made explicit (no separate-era residue)"
		return 0
	fi
	rm -f "$PICK_LST"
	printf 'Mix them into my folders (recommended)\nKeep them in separate folders\n' > "$PICK_LST"
	pick "Where should RomM games go?" "CHOOSE"; _emm_rc=$?
	case "$_emm_rc" in
		0)
			case "$PICK_VAL" in
				"Mix them into"*)
					if set_mirror_mode merge; then
						ui_msg_timed "RomM games will mix into your folders. Run Refresh library to tidy up the old ones - your own files are never modified." 5
					else
						ui_error_ack "Couldn't save the setting - check the SD card"
					fi
					;;
				"Keep them"*)
					if set_mirror_mode separate; then
						ui_msg_timed "RomM games stay in their own folders." 3
					else
						ui_error_ack "Couldn't save the setting - check the SD card"
					fi
					;;
			esac
			;;
		*) log "coexist: consent prompt dismissed - will ask again next open" ;;
	esac
	return 0
}

# get_fetch_covers — the engine's bulk box-art toggle, resolved with the ENGINE'S precedence:
# settings.conf fetch_covers=on|off overrides config.json "fetch_covers"; absent everywhere = off
# (the engine's opt-in default — --download still fetches the downloaded game's own cover always).
get_fetch_covers() {
	_fc="$(sed -n 's/^fetch_covers=//p' "$SETTINGS" 2>/dev/null | head -1)"
	case "$_fc" in on) echo on; return 0 ;; off) echo off; return 0 ;; esac
	if grep -q '"fetch_covers"[[:space:]]*:[[:space:]]*true' "$LODOR_CFG_DIR/config.json" 2>/dev/null; then
		echo on
	else
		echo off
	fi
}
toggle_fetch_covers() {
	if [ "$1" = on ]; then _fnew=off; else _fnew=on; fi
	if set_setting fetch_covers "$_fnew"; then
		if [ "$_fnew" = on ]; then
			ui_msg_timed "Box art for your whole library will download on the next Refresh library (can be slow)." 4
		else
			ui_msg_timed "Only downloaded games fetch box art now. Art already on the card is kept." 4
		fi
	else
		ui_error_ack "Couldn't save the setting - check the SD card"
	fi
}

# sd_free — human free space on the SD card ("12.4G"/"850M"), empty when df can't say (never guess).
sd_free() {
	df -k "$SDCARD" 2>/dev/null | awk 'NR>1 { a = $(NF-2) } END {
		if (a == "" || a !~ /^[0-9]+$/) exit
		a += 0
		if      (a >= 1048576) printf "%.1fG", a/1048576
		else if (a >= 1024)    printf "%dM", int(a/1024)
		else                   printf "%dK", a }'
}

# count_lines <file> — non-blank line count; 0 for a missing/unreadable file. Local-only (no
# network): drives the "(N)" labels on the pending-saves / download-queue menu rows.
count_lines() {
	_cl=0
	[ -f "$1" ] && _cl="$(grep -c . "$1" 2>/dev/null)"
	case "$_cl" in ''|*[!0-9]*) _cl=0 ;; esac
	echo "$_cl"
}

# active_profile_label — the ACTIVE profile's label, resolved locally the same way the engine does
# (active-profile.txt names it; absent -> hosts[0]'s profile_label, else username, else "Default").
# Pure file reads so drawing the menu never shells the engine or the network.
active_profile_label() {
	_ap="$(head -1 "$LODOR_CFG_DIR/active-profile.txt" 2>/dev/null | tr -d '\r')"
	if [ -n "$_ap" ]; then printf '%s' "$_ap"; return 0; fi
	_ap="$(sed -n 's/.*"profile_label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LODOR_CFG_DIR/config.json" 2>/dev/null | head -1)"
	[ -z "$_ap" ] && _ap="$(sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LODOR_CFG_DIR/config.json" 2>/dev/null | head -1)"
	printf '%s' "${_ap:-Default}"
}

# diagnose <rc> — turn a failed engine call into an HONEST cause. Re-checks cheap LOCAL preconditions
# then TRUSTS the engine's own exit code (the pure-Go engine's happy-eyeballs connect is authoritative;
# we deliberately do NOT pre-probe RomM with busybox nc — a known false-negative on this device).
# romm-run's RESERVED wrapper codes (#2) are mapped first: 101 = the pak itself is broken (missing
# binary/lib — never a network problem), 102 = Wi-Fi down (2 kept for a stale pre-#2 wrapper). An
# UNKNOWN rc never claims "check Wi-Fi" — it says so and points at the log.
diagnose() {
	if   [ ! -x "$SYNC_BIN" ];                 then echo "Lodor engine missing - reinstall from the Pak Store"
	elif [ "${1:-1}" = 101 ];                  then echo "Lodor is broken on this card - reinstall it from the Pak Store"
	elif ! creds_present;                      then echo "Not connected - run Lodor setup, then retry"
	elif [ "${1:-1}" = 6 ];                    then echo "Pairing expired - run Setup / Re-pair"
	elif [ "${1:-1}" = 102 ] || [ "${1:-1}" = 2 ]; then echo "Wi-Fi not connected - enable it in NextUI Settings, then retry"
	elif ! _radio_ready;                       then echo "Wi-Fi not connected - enable it in NextUI Settings, then retry"
	elif [ "${1:-1}" = 3 ];                    then echo "Couldn't reach your server - check the server or your connection, then retry"
	elif [ "${1:-1}" = 4 ];                    then echo "Sync finished with errors - some items didn't sync, try again"
	else                                            echo "Sync failed (rc=${1:-?}) - unknown cause, try again (details in last-sync.log)"
	fi
}

trap 'ui_stop; ui_clear; wifi_release' EXIT INT TERM HUP QUIT

# Engine must exist for BOTH the wizard and the client. (Wi-Fi / pairing checked per-action so the
# offline-safe Coexist toggle stays reachable with Wi-Fi off.)
if [ ! -x "$SYNC_BIN" ]; then
	ui_error_ack "Lodor engine missing - reinstall from the Pak Store"
	exit 1
fi

# ==================================================================================================
# ONBOARDING WIZARD (merged from the former "Lodor Setup.pak"). Runs when the device is not yet
# configured, and on demand from the client menu's "Setup / Re-pair" entry. Shells the engine's
# onboarding modes (all RomM logic in the engine; this only draws the keyboard/list/status):
#     --set-server <url> [--port N] [--insecure]   -> RESULT server_set=<0|1>   (offline write)
#     --pair <code>                                -> RESULT paired=<0|1> scopes_ok=<0|1>
#     --register-device <name>                     -> RESULT registered=<0|1>
# The engine owns config.json (merge-tree writer: a pre-seeded cf_access block for a Cloudflare-
# Access-gated server is PRESERVED across --set-server / --pair — see the wiki's "Reaching Your RomM
# Server"). This wizard writes NOTHING itself.
# ==================================================================================================
KB_OUT="/tmp/lodor-setup-kb"
PICK_OUT="/tmp/lodor-setup-pick"
PICK_LST="/tmp/lodor-setup-pick-list"

# kb <title> <initial> -> KB_VAL set to the typed text. Return: 0 confirmed, 2 back (B), 3 menu,
# other = keyboard render error. minui-keyboard contract is identical to the stock Wifi.pak's.
KB_VAL=""
kb() {
	rm -f "$KB_OUT"
	killall minui-presenter >/dev/null 2>&1 || true
	if [ ! -x "$KBBIN" ]; then
		ui_error_ack "On-screen keyboard missing - reinstall the Lodor pak"
		return 9
	fi
	"$KBBIN" --title "$1" --initial-value "$2" --write-location "$KB_OUT"
	_krc=$?
	KB_VAL="$(cat "$KB_OUT" 2>/dev/null)"
	return "$_krc"
}

# pick <title> <confirm-text>  (items already written to $PICK_LST) -> PICK_VAL. Return list rc.
PICK_VAL=""
pick() {
	rm -f "$PICK_OUT"
	killall minui-presenter >/dev/null 2>&1 || true
	if [ ! -x "$LISTBIN" ]; then
		ui_msg_timed "Menu renderer missing - reinstall the Lodor pak" 4
		return 9
	fi
	"$LISTBIN" --disable-auto-sleep --file "$PICK_LST" --format text \
		--title "$1" --confirm-text "$2" --cancel-text "BACK" \
		--write-location "$PICK_OUT"
	_prc=$?
	PICK_VAL="$(cat "$PICK_OUT" 2>/dev/null)"
	return "$_prc"
}

# NET_OUT / NET_RC — run a NETWORK engine mode through romm-run (clock + resolver + rides NextUI
# Wi-Fi). Captures combined stdout+stderr so the honest RESULT / *FAIL line is parseable.
NET_OUT=""; NET_RC=0
run_net() {
	NET_OUT="$("$RUN" "$@" 2>&1)"; NET_RC=$?
	printf '%s\n' "=== $* (rc=$NET_RC) ===" >> "$LOG"
	printf '%s\n' "$NET_OUT" >> "$LOG"
	note_net_rc "$NET_RC"
}

# eng_offline — run an OFFLINE engine mode (set-server writes config only). No Wi-Fi required. CWD =
# LODOR_CFG_DIR (the pak dir now, #30) so config.json lands there; env mirrors romm-run. Sets NET_OUT/RC.
eng_offline() {
	NET_OUT="$(cd "$LODOR_CFG_DIR" 2>/dev/null && \
		BASE_PATH="$SDCARD" SDCARD_PATH="$SDCARD" PLATFORM="$PLAT" LODOR_PAK_DIR="$LODOR_PAK_DIR" \
		"$SYNC_BIN" "$@" 2>&1)"
	NET_RC=$?
	printf '%s\n' "=== offline $* (rc=$NET_RC) ===" >> "$LOG"
	printf '%s\n' "$NET_OUT" >> "$LOG"
}

# eng_progress <label> <NETWORK engine mode...> (#1) — run the engine in the BACKGROUND and stream
# its REAL progress side-channels to the screen while it works: a numeric /tmp/dl-progress drives
# the bar, /tmp/romm-phase mirrors the engine's human phase label — the EXACT bridge the fetch
# hook streams downloads with (one pattern, not two). Never fabricates forward progress: no
# side-channel data = the label stands. Output -> $LOG; pairing flag noted; returns the engine rc.
eng_progress() {
	_eplbl="$1"; shift
	rm -f /tmp/dl-progress /tmp/romm-phase 2>/dev/null
	killall minui-presenter >/dev/null 2>&1 || true
	ui_begin "$_eplbl"
	"$RUN" "$@" >> "$LOG" 2>&1 &
	_eppid=$!
	while kill -0 "$_eppid" 2>/dev/null; do
		_eppct=""; [ -f /tmp/dl-progress ] && _eppct="$(cat /tmp/dl-progress 2>/dev/null)"
		case "$_eppct" in
			''|*[!0-9]*)
				_epph=""; [ -f /tmp/romm-phase ] && _epph="$(cat /tmp/romm-phase 2>/dev/null)"
				[ -n "$_epph" ] && ui_set "$_epph"
				;;
			*)
				ui_set "$_eplbl  ${_eppct}%" "$_eppct"
				;;
		esac
		sleep 0.3
	done
	wait "$_eppid"; _eprc=$?
	ui_stop
	log "eng_progress: $* rc=$_eprc"
	note_net_rc "$_eprc"
	return "$_eprc"
}

# require_wifi — honest Wi-Fi precondition for network steps (NextUI owns the radio; we only ride it).
require_wifi() {
	if _radio_ready; then return 0; fi
	ui_msg "Waiting for Wi-Fi..."
	if _radio_wait 8; then ui_clear; return 0; fi
	if _have_up; then ui_error_ack "Wi-Fi still connecting - try again in a moment"
	else ui_error_ack "Connect Wi-Fi in NextUI Settings first, then re-run Lodor setup"; fi
	return 1
}

# cf_note — one honest heads-up if a cf_access block is already present (pre-seeded for a
# Cloudflare-Access-gated server). The engine preserves it; we never touch or print it.
cf_note() {
	if [ -f "$LODOR_CFG_DIR/config.json" ] && grep -q '"cf_access"' "$LODOR_CFG_DIR/config.json" 2>/dev/null; then
		ui_msg_timed "Cloudflare Access config found - pairing will use it" 3
		log "cf_access present: preserving"
	fi
}

# default device name per platform
default_devname() {
	case "$PLAT" in
		tg5040) echo "TrimUI Brick" ;;
		tg5050) echo "TrimUI Smart Pro" ;;
		*)      echo "NextUI Device" ;;
	esac
}

# STEP: server address. Sets scheme + host (+ optional port + TLS skip) and persists via --set-server.
# Returns 0 on a written server, 1 on user-cancel/abort.
OB_HOST=""; OB_HTTPS=1; OB_PORT=""; OB_INSECURE=0
step_server() {
	# protocol
	printf 'https (secure, recommended)\nhttp (plain)\n' > "$PICK_LST"
	pick "RomM server protocol" "SELECT"; _rc=$?
	[ "$_rc" = 0 ] || return 1
	# NB: https must be matched BEFORE the http glob — `http*` alone also matches the
	# "https (secure, recommended)" label, which silently downgraded every onboarding to
	# http:// and made the TLS question unreachable. Found by wizard-sim 2026-07-02.
	case "$PICK_VAL" in https*) OB_HTTPS=1 ;; http*) OB_HTTPS=0 ;; *) OB_HTTPS=1 ;; esac

	# hostname (strip any scheme the user pastes + a trailing slash)
	# Prefill: current wizard value, else the last address saved in config.json — so a failed
	# pair (typo'd host, wrong scheme) is a two-key EDIT on re-run, not a 30-char d-pad retype.
	if [ -z "$OB_HOST" ] && [ -f "$LODOR_CFG_DIR/config.json" ]; then
		OB_HOST="$(sed -n 's/.*"root_uri"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LODOR_CFG_DIR/config.json" | head -1 | sed 's#^https\{0,1\}://##; s#/$##')"
	fi
	kb "RomM server address (e.g. romm.example.com)" "$OB_HOST"; _rc=$?
	[ "$_rc" = 0 ] || return 1
	_h="$KB_VAL"
	_h="$(printf '%s' "$_h" | sed -e 's#^[Hh][Tt][Tt][Pp][Ss]\{0,1\}://##' -e 's#/*$##')"
	if [ -z "$_h" ]; then ui_msg_timed "Server address can't be empty" 3; return 2; fi
	# INLINE PORT (UX, 2026-07-02): a pasted/typed "host:8443" carries its own port — parse it and
	# skip the separate port question (4 wizard interactions -> 3 for the common paste). Only a
	# clean, all-numeric suffix counts; anything odd falls through to the explicit port step so
	# weird input is never silently mangled.
	_inline_port=0
	case "$_h" in
		*:*)
			_hp="${_h##*:}"
			case "$_hp" in
				''|*[!0-9]*) : ;;   # not a numeric port -> leave the address as typed, ask below
				*) OB_PORT="$_hp"; _h="${_h%:*}"; _inline_port=1 ;;
			esac ;;
	esac
	OB_HOST="$_h"

	# optional port (skipped when the address carried one inline). B/menu/render-fail here keeps
	# the prior/blank value and is NOT an abort — only a confirm updates it (the old code fell
	# through and wiped a previously-typed port on every non-confirm; found by wizard-sim 2026-07-02).
	if [ "$_inline_port" != 1 ]; then
		_pval="$OB_PORT"
		while :; do
			kb "Port (leave blank for default)" "$_pval"; _rc=$?
			[ "$_rc" = 0 ] || break   # B/menu/render-fail keeps the prior value (not an abort)
			case "$KB_VAL" in
				"" ) OB_PORT=""; break ;;
				*[!0-9]* )
					# INVALID PORT (#5): never silently discard — loop back into the keyboard
					# with the typed value preserved, so fixing it is an edit, not a retype.
					_pval="$KB_VAL"
					ui_msg_timed "Port must be a number - edit or clear it" 3
					;;
				* ) OB_PORT="$KB_VAL"; break ;;
			esac
		done
	fi

	# TLS skip (HTTPS only)
	OB_INSECURE=0
	if [ "$OB_HTTPS" = 1 ]; then
		printf 'Verify TLS certificate (recommended)\nSkip verification (self-signed)\n' > "$PICK_LST"
		pick "TLS certificate" "SELECT"; _rc=$?
		[ "$_rc" = 0 ] || return 1
		case "$PICK_VAL" in Skip*) OB_INSECURE=1 ;; *) OB_INSECURE=0 ;; esac
	fi

	# build URL + persist (offline write; preserves any pre-seeded cf_access)
	if [ "$OB_HTTPS" = 1 ]; then _url="https://$OB_HOST"; else _url="http://$OB_HOST"; fi
	set -- --set-server "$_url"
	[ -n "$OB_PORT" ] && set -- "$@" --port "$OB_PORT"
	[ "$OB_INSECURE" = 1 ] && set -- "$@" --insecure
	ui_msg "Saving server address..."
	eng_offline "$@"
	ui_clear
	if [ "$NET_RC" = 0 ] && printf '%s' "$NET_OUT" | grep -q 'server_set=1'; then
		log "set-server ok: $_url (port=${OB_PORT:-none} insecure=$OB_INSECURE)"
		return 0
	fi
	_why="$(printf '%s\n' "$NET_OUT" | grep -a 'SETSERVERFAIL' | tail -1)"
	ui_error_ack "${_why:-Could not save the server address} - check it and retry"
	return 2
}

# STEP: pairing code. Requires Wi-Fi. Distinguishes unreachable (rc3) from bad/expired code (rc4).
step_pair() {
	require_wifi || return 1
	cf_note
	kb "RomM pairing code" ""; _rc=$?
	[ "$_rc" = 0 ] || return 1
	_code="$(printf '%s' "$KB_VAL" | tr -d ' \t\r\n')"
	if [ -z "$_code" ]; then ui_msg_timed "Pairing code can't be empty" 3; return 2; fi
	ui_msg "Pairing with your server..."
	run_net --pair "$_code"
	ui_clear
	if [ "$NET_RC" = 0 ] && printf '%s' "$NET_OUT" | grep -q 'paired=1'; then
		if printf '%s' "$NET_OUT" | grep -q 'scopes_ok=0'; then
			ui_msg_timed "Paired - but the token is missing some sync permissions. Re-generate it in RomM with all scopes." 6
		else
			ui_msg_timed "Paired." 2
		fi
		return 0
	fi
	# honest failure: prefer the engine's own PAIRFAIL reason
	_why="$(printf '%s\n' "$NET_OUT" | grep -a 'PAIRFAIL' | tail -1 | sed 's/^PAIRFAIL /Pairing failed: /')"
	if [ -z "$_why" ]; then
		case "$NET_RC" in
			3) _why="Couldn't reach your server - check the address and Wi-Fi" ;;
			*) _why="Pairing failed (rc=$NET_RC) - check the code and try again" ;;
		esac
	fi
	ui_error_ack "$_why"
	return 2
}

# STEP: device name -> --register-device. Requires Wi-Fi (writes device_id from the server).
step_device() {
	require_wifi || return 1
	kb "Name this device" "$(default_devname)"; _rc=$?
	[ "$_rc" = 0 ] || return 1
	_name="$KB_VAL"
	if [ -z "$_name" ]; then ui_msg_timed "Device name can't be empty" 3; return 2; fi
	ui_msg "Registering this device..."
	run_net --register-device "$_name"
	ui_clear
	if [ "$NET_RC" = 0 ] && printf '%s' "$NET_OUT" | grep -q 'registered=1'; then
		ui_msg_timed "Registered as \"$_name\"." 2
		return 0
	fi
	_why="$(printf '%s\n' "$NET_OUT" | grep -a 'REGFAIL' | tail -1 | sed 's/^REGFAIL /Register failed: /')"
	[ -z "$_why" ] && _why="Couldn't register this device (rc=$NET_RC) - try again"
	ui_error_ack "$_why"
	return 2
}

# STEP: first library mirror (optional; the client also seeds on first open). Best-effort.
step_seed() {
	require_wifi || return 0
	# LIVE progress (#1): stream the engine's real phase/percent through the first mirror.
	eng_progress "Downloading your game library..." --mirror-catalog
	eng_progress "Downloading your collections..." --mirror-collections
	ui_clear
	return 0
}

# run_wizard — linear onboarding with back-navigation; every step re-enterable so a failed pair just
# retries. Returns 0 when the flow ran to completion, 1 on user-cancel. The caller re-checks
# creds_present to decide whether onboarding actually succeeded.
run_wizard() {
	OB_TIER1=0
	# Network reach choice (only surfaced where Tailscale is available: tg5040 / tg5050). Home /
	# public-URL both just proceed to the normal server-address entry; Tailscale runs the QR sign-in
	# FIRST — the tunnel must be up before the MagicDNS server is written/paired.
	if ts_available; then
		while :; do
			printf 'Tailscale (sign in with QR)\nHome network / public URL\n' > "$PICK_LST"
			pick "How will you reach RomM?" "SELECT"; _nc=$?
			# 0=picked; ANYTHING else (2=back, 3=menu, 9=render fail) exits the wizard cleanly —
			# B must always back out to NextUI (a Wi-Fi-less user was trapped here otherwise).
			[ "$_nc" = 0 ] || return 1
			case "$PICK_VAL" in
				Tailscale*) if ts_onboard; then OB_TIER1=1; break; fi ;;
				*)          OB_TIER1=0; break ;;
			esac
		done
	fi
	# server (retry on soft failure, abort on cancel)
	[ "$OB_TIER1" = 1 ] && ui_msg_timed "Enter your RomM's Tailscale address. If it uses tailscale serve, use httpS (e.g. https://romm.your-tailnet.ts.net)." 5
	while :; do
		step_server; _s=$?
		[ "$_s" = 0 ] && break
		[ "$_s" = 1 ] && return 1        # user cancelled
	done
	# tier-1: mark the just-written host as a SOCKS5 (Tailscale) endpoint BEFORE pairing so
	# --pair / --register-device route through the tunnel (the engine reads socks5_proxy + tier).
	[ "$OB_TIER1" = 1 ] && { tailscale_mark_tier1 >/dev/null 2>&1 || true; }
	# pair
	while :; do
		step_pair; _p=$?
		[ "$_p" = 0 ] && break
		[ "$_p" = 1 ] && return 1
	done
	# device
	while :; do
		step_device; _d=$?
		[ "$_d" = 0 ] && break
		[ "$_d" = 1 ] && return 1
	done
	step_seed
	ui_msg_timed "Connected! Your library is syncing. Open it from the NextUI menu." 5
	return 0
}

# ==================================================================================================
# CLIENT ACTIONS. Each is a THIN shell over ONE engine mode (host rendering only; all RomM logic stays
# in the engine). Wi-Fi precondition is checked the same honest way everywhere.
# ==================================================================================================
# do_sync_now — the FAST sync (task #133). Saves + Continue only, NO catalog/collections mirror:
#   --push-pending   flush the offline save queue
#   --pull-saves     targeted pulls: only on-card games that have a real server save (newest-wins)
#   --sync-continue  light Continue collection + cross-device Recently Played merge (local index,
#                    no catalog pass — the full derivation still rides Refresh library)
# The 0.9.1-beta test showed the old "Sync now" (which ran the full --mirror-catalog +
# --mirror-collections) taking library-scale minutes; library refresh is its own honest button now.
do_sync_now() {
	_require_online || return $?
	ui_msg "Flushing pending saves..."
	"$RUN" --push-pending >> "$LOG" 2>&1; _r1=$?
	# Manual Sync now also force-pushes ALL local savestates (not just the pending queue),
	# so a hands-on sync guarantees every on-card state is up on the server. Best-effort —
	# --push-all-states is the wide state mode; a state hiccup must not fail the save sync.
	"$RUN" --push-all-states >> "$LOG" 2>&1 || true
	ui_msg "Pulling latest saves..."
	"$RUN" --pull-saves >> "$LOG" 2>&1; _r2=$?
	ui_msg "Updating Continue..."
	"$RUN" --sync-continue >> "$LOG" 2>&1; _r3=$?
	_rc=0; for _r in $_r1 $_r2 $_r3; do [ "$_r" -gt "$_rc" ] && _rc=$_r; done
	note_net_rc "$_rc"
	if [ "$_rc" = 0 ]; then ui_msg_timed "Sync complete" 2; else ui_error_ack "$(diagnose "$_rc")"; fi
	[ "$_rc" = 0 ] && maybe_check_updates
	return "$_rc"
}

# ---- self-update notices (store lane) -----------------------------------------------------------
# On NextUI, updates INSTALL through the first-party Pak Store — Lodor only CHECKS and points
# there (no bespoke apply on this lane; the store's extract-over update honors update_ignore).
# --check-update is engine-side (versions.json, gh-pages; honest exit 3 = unreachable). The SHELL
# owns every settings.conf stamp (update_available / update_last_check) — single-writer, same as
# mirror_mode. The engine only ever READS update_channel from settings.conf.
current_engine_version() {
	"$SYNC_BIN" --version 2>/dev/null | awk '{print $2}'
}
# stamp_update_state <RESULT line> — update_available is set from update=1, CLEARED on update=0
# (an installed update self-clears the badge on the next check); last_check stamps on every
# successful check so the once-a-day gate below works.
stamp_update_state() {
	_ulatest="$(printf '%s\n' "$1" | sed -n 's/.*latest=\([^ ]*\).*/\1/p')"
	case "$1" in
		*"update=1"*) set_setting update_available "$_ulatest" ;;
		*)            set_setting update_available "" ;;
	esac
	set_setting update_last_check "$(date +%s)"
}
do_check_updates() {
	require_wifi || return 1
	ui_msg "Checking for updates..."
	run_net --check-update
	_url="$(printf '%s\n' "$NET_OUT" | grep -a '^RESULT update=' | tail -1)"
	if [ "$NET_RC" != 0 ] || [ -z "$_url" ]; then
		ui_error_ack "Couldn't reach the update server - this check needs internet, not just your RomM server"
		return 1
	fi
	stamp_update_state "$_url"
	_ulatest="$(printf '%s\n' "$_url" | sed -n 's/.*latest=\([^ ]*\).*/\1/p')"
	_ucur="$(printf '%s\n' "$_url" | sed -n 's/.*current=\([^ ]*\).*/\1/p')"
	case "$_url" in
		*"update=1"*)
			_unotes="$(printf '%s\n' "$NET_OUT" | grep -a "^NOTES" | tail -1 | cut -f2-)"
			ui_msg_timed "Lodor $_ulatest is out (you have $_ucur). Install it from the Pak Store.${_unotes:+ New: $_unotes}" 8
			;;
		*)
			ui_msg_timed "You're up to date ($_ucur)" 3
			;;
	esac
	return 0
}
# maybe_check_updates — opportunistic tail of a good Sync now: the radio is already up, so the
# manifest GET is nearly free. At most once a day; EVERY failure is silent (a background path
# never nags and never touches the radio). Shows an honest one-liner because it does add a
# beat of wait after "Sync complete" — no invisible stalls.
maybe_check_updates() {
	_ulast="$(sed -n 's/^update_last_check=//p' "$SETTINGS" 2>/dev/null | head -1)"
	case "$_ulast" in ''|*[!0-9]*) _ulast=0 ;; esac
	[ $(($(date +%s) - _ulast)) -lt 86400 ] && return 0
	ui_msg "Checking for updates..."
	run_net --check-update
	_url="$(printf '%s\n' "$NET_OUT" | grep -a '^RESULT update=' | tail -1)"
	[ "$NET_RC" = 0 ] && [ -n "$_url" ] && stamp_update_state "$_url"
	ui_clear
	return 0
}

# lib_counts — on-card library totals (games/systems) from the stub mirror, which IS the whole
# catalog on card. Excludes the Game Manager's own folder, hidden files, and map.txt. Ground truth
# by construction (counts what is really there, not what the engine claims).
lib_counts() {
	LIB_GAMES=0; LIB_SYS=0
	for _ld in "$SDCARD/Roms"/*/; do
		[ -d "$_ld" ] || continue
		_lb="$(basename "$_ld")"
		case "$_lb" in .*|*"($GM_TAG)"|*"($CT_TAG)") continue ;; esac
		_lc="$(find "$_ld" -mindepth 1 -maxdepth 1 -type f ! -name '.*' ! -name map.txt 2>/dev/null | wc -l | tr -d ' \t')"
		[ "$_lc" -gt 0 ] 2>/dev/null || continue
		LIB_SYS=$((LIB_SYS + 1)); LIB_GAMES=$((LIB_GAMES + _lc))
	done
}

# refresh_report <base message> — the honest post-mirror summary the old "Library refreshed" hid:
# real on-card totals + the engine's own MIRROR created= count for "new". Falls back to the plain
# base message when the card scan finds nothing (never fabricates numbers).
refresh_report() {
	lib_counts
	_rr="$1"
	if [ "$LIB_GAMES" -gt 0 ] 2>/dev/null; then
		_gw=games; [ "$LIB_GAMES" = 1 ] && _gw=game
		_sw=systems; [ "$LIB_SYS" = 1 ] && _sw=system
		_rr="$_rr - $LIB_GAMES $_gw across $LIB_SYS $_sw"
		_new="$(grep -a '^MIRROR created=' "$LOG" 2>/dev/null | tail -1 | sed -n 's/.*created=\([0-9][0-9]*\).*/\1/p')"
		[ -n "$_new" ] && [ "$_new" -gt 0 ] 2>/dev/null && _rr="$_rr ($_new new)"
	fi
	printf '%s' "$_rr"
}

do_refresh_library() {
	_require_online || return $?
	# LIVE progress (#1): the full mirror can take minutes on a big library — background the
	# engine and stream its real phase/percent side-channels (the fetch hook's exact bridge)
	# instead of a static message. The final honest report is unchanged.
	eng_progress "Refreshing your library..." --mirror-catalog; _r1=$?
	eng_progress "Refreshing collections..." --mirror-collections; _r2=$?
	_rc=0; for _r in $_r1 $_r2; do [ "$_r" -gt "$_rc" ] && _rc=$_r; done
	if [ "$_rc" = 0 ]; then ui_msg_timed "$(refresh_report 'Library refreshed')" 3; else ui_error_ack "$(diagnose "$_rc")"; fi
	return "$_rc"
}

# do_push_pending — flush the offline save queue on demand (parity item #2: the row surfaces N so
# saves parked offline are never invisible). Reports the engine's pushed/stuck split honestly.
do_push_pending() {
	_require_online || return $?
	ui_msg "Uploading pending saves..."
	run_net --push-pending
	ui_clear
	if [ "$NET_RC" != 0 ]; then ui_error_ack "$(diagnose "$NET_RC")"; return 1; fi
	_pl="$(printf '%s\n' "$NET_OUT" | grep -a '^RESULT pushed=' | tail -1)"
	_pu="$(printf '%s\n' "$_pl" | sed -n 's/.*pushed=\([0-9][0-9]*\).*/\1/p')"
	_st="$(printf '%s\n' "$_pl" | sed -n 's/.*stuck=\([0-9][0-9]*\).*/\1/p')"
	if [ -n "$_st" ] && [ "$_st" -gt 0 ] 2>/dev/null; then
		ui_msg_timed "Uploaded ${_pu:-0} save(s) - $_st still stuck (kept queued, will retry)" 4
	else
		ui_msg_timed "Uploaded ${_pu:-0} save(s)" 3
	fi
	return 0
}

toggle_coexist() {
	_cur="$1"
	# Toggle merge <-> separate (C2: merge is the default). "own" (a LodorOS / remediation state,
	# not a NextUI choice) exits to merge and is never re-entered from the menu. Writing the mode
	# here IS the migration consent: the engine only ever restructures a card on an EXPLICIT mode
	# (prompt-only), and the merge migration pushes every affected save lineage through the
	# verified funnel before removing any of its own stub twins.
	case "$_cur" in
		separate) _next=merge ;;
		*)        _next=separate ;;
	esac
	if set_mirror_mode "$_next"; then
		case "$_next" in
			separate) ui_msg_timed "RomM games get their own folders. Run Refresh library to apply." 3 ;;
			merge)    ui_msg_timed "RomM games mix into your folders - your own files are never modified. Run Refresh library to apply." 4 ;;
		esac
	else
		ui_error_ack "Couldn't save the setting - check the SD card"
	fi
}

# do_uninstall_lodor — "Remove Lodor from this card" (C2 §5). The ENGINE removes exactly what its
# manifest owns (stubs, its covers/collections/folders; saves never; user files byte-identical) —
# downloads are kept unless the user explicitly picks the second option. Then the pak removes its
# own delivery surface (hooks, root entries, daemon, recents rows). Offline-safe.
do_uninstall_lodor() {
	rm -f "$PICK_LST"
	printf 'Keep my downloaded games\nAlso remove downloaded games\n' > "$PICK_LST"
	pick "Remove Lodor from this card?" "REMOVE"; _un_rc=$?
	[ "$_un_rc" = 0 ] || return 0
	_un_flag=""
	case "$PICK_VAL" in "Also remove"*) _un_flag="--remove-downloads" ;; esac
	ui_msg "Removing Lodor files..."
	# shellcheck disable=SC2086  # _un_flag is deliberately empty-or-one-flag
	_un_out="$("$RUN" --uninstall-mirror $_un_flag 2>>"$LOG")"
	log "uninstall: $_un_out"
	_un_ok="$(printf '%s\n' "$_un_out" | sed -n 's/.*uninstalled=\([01]\).*/\1/p')"
	_un_n="$(printf '%s\n' "$_un_out" | sed -n 's/.*removed=\([0-9][0-9]*\).*/\1/p')"
	# Pak delivery surface: hooks, root entries, daemon, recents rows, seed sentinel.
	killall romm-syncd >/dev/null 2>&1 || true
	if [ -n "${SDCARD_PATH:-}" ] && [ -n "${PLATFORM:-}" ]; then
		for _un_hd in pre-launch.d post-launch.d boot.d; do
			for _un_src in "$PAKDIR/hooks/$_un_hd/"*; do
				[ -f "$_un_src" ] || continue
				rm -f "$SDCARD_PATH/.userdata/$PLATFORM/.hooks/$_un_hd/$(basename "$_un_src")" 2>/dev/null
			done
		done
	fi
	rm -rf "$SDCARD/Roms/$GM_DIRNAME" "$SDCARD/Roms/$GM_DIRNAME_OLD" "$SDCARD/Roms/$CT_DIRNAME" 2>/dev/null
	rm -rf "$SDCARD/Emus/$PLAT/$GM_TAG.pak" "$SDCARD/Emus/$PLAT/$CT_TAG.pak" 2>/dev/null
	scrub_recents
	rm -f "$SEED_SENTINEL" 2>/dev/null
	# Credential wipe (fixes #30): config.json / settings.conf / active-profile.txt now live in the
	# pak dir, so removing them here means a "Remove Lodor" that keeps downloads still clears the RomM
	# token immediately (not only when the user later deletes the pak dir). Also sweep the OLD shared
	# home in case a pre-#30 install left creds there (belt-and-suspenders; migration usually moved them).
	for _un_cf in config.json settings.conf active-profile.txt .pairing-expired; do
		rm -f "$LODOR_CFG_DIR/$_un_cf" "${SHARED_USERDATA_PATH:-$SDCARD/.userdata/shared}/Lodor/$_un_cf" 2>/dev/null
	done
	ui_clear
	if [ "$_un_ok" = 1 ]; then
		ui_msg_timed "Removed ${_un_n:-0} Lodor file(s) and cleared pairing. Delete Tools/$BINPLAT/Lodor.pak to finish." 6
	else
		ui_error_ack "Nothing removed - Lodor's file records were missing. Run Refresh library once, then retry."
	fi
	return 0
}

_require_online() {   # creds + a usable radio, or an honest dismissable error + non-zero. Used by net actions.
	if ! creds_present; then ui_error_ack "Not connected - run Lodor setup, then retry"; return 2; fi
	if ! _radio_ready; then
		ui_msg "Waiting for Wi-Fi..."
		if ! _radio_wait 8; then
			if _have_up; then ui_error_ack "Wi-Fi still connecting - try again in a moment"
			else ui_error_ack "Wi-Fi not connected - enable it in NextUI Settings, then retry"; fi
			return 1
		fi
	fi
	return 0
}

do_download_queue() {   # --download-queue: fetch every ROM queued in download-queue.txt
	_require_online || return $?
	ui_msg "Downloading queued games..."
	"$RUN" --download-queue >> "$LOG" 2>&1; _rc=$?
	note_net_rc "$_rc"
	# Engine prints RESULT downloaded=<N> failed=<M> remaining=<K> to the log; report honestly.
	_line="$(grep -a '^RESULT downloaded=' "$LOG" 2>/dev/null | tail -1)"
	if [ "$_rc" = 0 ]; then ui_msg_timed "${_line:-Download queue complete}" 3
	else ui_error_ack "$(diagnose "$_rc")"; fi
	return "$_rc"
}

do_download_bios() {    # --download-bios: BYOB pull of firmware for every mapped platform
	_require_online || return $?
	ui_msg "Downloading BIOS files..."
	"$RUN" --download-bios >> "$LOG" 2>&1; _rc=$?
	note_net_rc "$_rc"
	_line="$(grep -a '^RESULT bios=' "$LOG" 2>/dev/null | tail -1)"
	if [ "$_rc" = 0 ]; then ui_msg_timed "${_line:-BIOS download complete}" 3
	else ui_error_ack "$(diagnose "$_rc")"; fi
	return "$_rc"
}

do_sync_feed() {        # --sync-feed: read-only list of recent cross-device saves
	_require_online || return $?
	ui_msg "Fetching recent activity..."
	# lodor#44: capture the engine rc BEFORE filtering - unreachable is rc=3 now and must
	# say so honestly, never masquerade as an empty feed.
	feed_raw="$("$RUN" --sync-feed 2>/dev/null)"; _rc=$?
	feed="$(printf '%s\n' "$feed_raw" | awk -F'\t' 'NF>=2')"
	ui_clear
	if [ "$_rc" != 0 ]; then ui_msg_timed "$(diagnose "$_rc")" 4; return 0; fi
	if [ -z "$feed" ]; then ui_msg_timed "No recent activity yet" 3; return 0; fi
	# Render the feed as a read-only minui-list (B exits). Each row: <game>  -  <when>  -  <device>.
	FEED_LST="/tmp/lodor-feed-list"; : > "$FEED_LST"
	TAB="$(printf '\t')"
	printf '%s\n' "$feed" | while IFS="$TAB" read -r g when who _rest; do
		printf '%s\n' "$g  -  $when  -  $who" >> "$FEED_LST"
	done
	if [ -x "$LISTBIN" ]; then
		killall minui-presenter >/dev/null 2>&1 || true
		"$LISTBIN" --disable-auto-sleep --file "$FEED_LST" --format text \
			--title "Recent activity" --confirm-text " " --cancel-text "BACK" \
			--write-location /tmp/lodor-feed-out >/dev/null 2>&1
	fi
	return 0
}

do_switch_user() {      # --list-profiles: pick an already-paired profile -> write active-profile.txt
	# Multi-user SWITCH is offline + shell-only: the active profile is named by active-profile.txt
	# (engine reads it CWD-relative in LODOR_CFG_DIR). Switching between ALREADY-PAIRED profiles needs
	# no network. ADDING a new user needs a typed pair code -> that is now done in-pak via the
	# "Setup / Re-pair" menu entry (the onboarding wizard), so here we direct the user there.
	lodor_migrate_cfg
	if ! creds_present; then ui_error_ack "Not connected - run Lodor setup, then retry"; return 2; fi
	profiles="$("$RUN" --list-profiles 2>/dev/null | awk -F'\t' 'NF>=2')"
	[ -z "$profiles" ] && profiles="$(BASE_PATH="$SDCARD" SDCARD_PATH="$SDCARD" PLATFORM="$PLAT" LODOR_PAK_DIR="$PAKDIR" sh -c "cd '$LODOR_CFG_DIR' 2>/dev/null && '$SYNC_BIN' --list-profiles" 2>/dev/null | awk -F'\t' 'NF>=2')"
	if [ -z "$profiles" ]; then ui_msg_timed "No profiles found - pair via Setup / Re-pair" 3; return 0; fi
	# --list-profiles: "<active>\t<label>\t<hastoken>\t<hasdevice>". Offer only signed-in (hastoken=1)
	# profiles to switch to; an unpaired row would need a pair code (use Setup / Re-pair for that).
	U_LST="/tmp/lodor-user-list"; U_IDS="/tmp/lodor-user-ids"; U_OUT="/tmp/lodor-user-out"
	: > "$U_LST"; : > "$U_IDS"; rm -f "$U_OUT"; TAB="$(printf '\t')"
	_n=0
	printf '%s\n' "$profiles" | while IFS="$TAB" read -r act label htok hdev; do
		[ "$htok" = 1 ] || continue
		_mark=""; [ "$act" = 1 ] && _mark="  (active)"
		printf '%s\n' "$label$_mark" >> "$U_LST"
		printf '%s\n' "$label" >> "$U_IDS"
	done
	if [ ! -s "$U_LST" ]; then ui_msg_timed "Only one signed-in profile - add more via Setup / Re-pair" 3; return 0; fi
	[ -x "$LISTBIN" ] || { ui_msg_timed "Switch User needs the menu renderer (missing)" 3; return 0; }
	killall minui-presenter >/dev/null 2>&1 || true
	"$LISTBIN" --disable-auto-sleep --file "$U_LST" --format text \
		--title "Switch User" --confirm-text "USE" --cancel-text "BACK" \
		--write-location "$U_OUT"
	urc=$?; usel="$(cat "$U_OUT" 2>/dev/null)"
	[ "$urc" = 0 ] && [ -n "$usel" ] || return 0
	uln="$(grep -n -F -x "$usel" "$U_LST" 2>/dev/null | head -1 | cut -d: -f1)"
	[ -n "$uln" ] || return 0
	ulabel="$(sed -n "${uln}p" "$U_IDS" 2>/dev/null)"
	[ -n "$ulabel" ] || return 0
	# Set the active profile (offline): the engine reads active-profile.txt from LODOR_CFG_DIR (CWD).
	if printf '%s\n' "$ulabel" > "$LODOR_CFG_DIR/active-profile.txt" 2>/dev/null; then
		ui_msg_timed "Switched to $ulabel" 2
		log "switch-user -> $ulabel"
	else
		ui_error_ack "Couldn't switch profile - check the SD card"
	fi
	return 0
}

# do_reonboard — client-menu entry point back into the onboarding wizard (re-pair / change server).
# Reached explicitly from the menu, so no "already connected?" confirmation gate — the user chose it.
do_reonboard() {
	log "re-onboard: user opened Setup / Re-pair"
	run_wizard; _wr=$?
	if [ "$_wr" = 0 ] && creds_present; then
		# a fresh pairing may point at a new server / library — allow first-open seed to re-run.
		rm -f "$SEED_SENTINEL" 2>/dev/null
	fi
	return 0
}

# maybe_seed_library — FIRST-RUN library population. Idempotent + honest: skips quietly when
# offline/unpaired (no sentinel -> retries next open), real error on failure, never fake progress.
maybe_seed_library() {
	[ -f "$SEED_SENTINEL" ] && return 0
	if ! creds_present; then log "first-run seed: skipped (RomM not paired)"; return 0; fi
	if ! _radio_wait 8;  then log "first-run seed: skipped (Wi-Fi not connected)"; return 0; fi
	# LIVE progress (#1): the first seed is the longest wait a new user ever sees — stream it.
	eng_progress "Downloading your game library..." --mirror-catalog; _s1=$?
	eng_progress "Downloading your collections..." --mirror-collections; _s2=$?
	_src=0; for _r in $_s1 $_s2; do [ "$_r" -gt "$_src" ] && _src=$_r; done
	if [ "$_src" = 0 ]; then
		: > "$SEED_SENTINEL" 2>/dev/null
		ui_msg_timed "$(refresh_report 'Library ready')" 3
		log "first-run seed: complete"
	else
		ui_error_ack "$(diagnose "$_src")"
		log "first-run seed: failed (catalog=$_s1 collections=$_s2) - will retry next open"
	fi
}

# ==================================================================================================
# GAME MANAGER (task #125). Stock NextUI has no per-item context-menu hook (a "Y menu"), and we
# never fork — so per-game management lives HERE as a Tool flow: pick a system, pick a game, act.
#
#   Picker source: the ON-CARD library (the mirrored stubs/files under Roms/), NOT the engine's
#   catalog-index.json — the card is the live truth (it includes fetch-on-launch downloads newer
#   than the last index write) and needs no JSON parsing in busybox ash. Scale: the pick is
#   TWO-LEVEL (system -> game), so each minui-list gets at most one platform's titles — the same
#   file-backed list widget the stock Wifi.pak scrolls, no argv limits, no paging code.
#   Downloaded-vs-stub state per game is FREE: the mirror bakes it into the filename (✘ cloud /
#   ✓ on device), so the list shows it with zero extra stat calls.
#
#   Actions are each a thin shell over ONE engine capability (host rendering only):
#     Download now   -> --download (the SAME capability the pre-launch fetch hook shells) then the
#                       offline --reconcile ✘->✓ flip — safe HERE because no launch is pending
#                       (in the hook window that rename would pull the file out from under the
#                       launcher, decision #69)
#     Delete from card -> --evict (offline): bytes removed, 0-byte cloud stub re-created, save +
#                       cover carried by the engine's rename — Saves/ is NEVER deleted
#     Sync save now  -> --sync-save (targeted pull-if-newer + push for this one ROM)
#     Server saves   -> --list-saves picker (ghost-aware) -> confirm -> --restore-save
#     Details        -> offline stat (name / system / on-card state / size)
# ==================================================================================================
GM_IDS="/tmp/lodor-gm-ids"

gm_human_size() {   # bytes -> short human string
	awk -v b="${1:-0}" 'BEGIN{
		if (b >= 1073741824)     printf "%.1f GB", b/1073741824;
		else if (b >= 1048576)   printf "%.1f MB", b/1048576;
		else                     printf "%d KB", int((b+1023)/1024) }'
}

gm_details() {      # offline: name / system / state+size / card free space. DISMISSABLE (any
	# button exits the read-only list — the old 6s timed message rushed slow readers and stuck
	# fast ones). Falls back to the timed message only if the list renderer is gone.
	_p="$1"; _b="$(basename "$_p")"
	_sys="$(basename "$(dirname "$_p")")"
	if [ -s "$_p" ]; then
		_bytes="$(wc -c < "$_p" 2>/dev/null | tr -d ' \t')"
		_state="On this card ($(gm_human_size "$_bytes"))"
	else
		_state="In your cloud library (not downloaded)"
	fi
	if [ -x "$LISTBIN" ]; then
		DET_LST="/tmp/lodor-details-list"
		{
			printf '%s\n' "$_b"
			printf 'System: %s\n' "$_sys"
			printf 'Status: %s\n' "$_state"
			_free="$(sd_free)"
			[ -n "$_free" ] && printf 'Free space on card: %s\n' "$_free"
		} > "$DET_LST"
		killall minui-presenter >/dev/null 2>&1 || true
		"$LISTBIN" --disable-auto-sleep --file "$DET_LST" --format text \
			--title "Details" --confirm-text "OK" --cancel-text "BACK" \
			--write-location /tmp/lodor-details-out >/dev/null 2>&1
	else
		ui_msg_timed "$_b  -  $_sys  -  $_state" 6
	fi
}

gm_download() {     # engine --download + offline ✘->✓ reconcile. 0 = path changed (caller rebuilds).
	_p="$1"; _name="$(basename "$_p")"
	_sys="$(basename "$(dirname "$_p")")"
	_require_online || return 1
	ui_msg "Downloading $_name..."
	run_net --download "$_p"
	ui_clear
	# HONEST success: engine said downloaded=1 AND the file really has bytes now.
	if [ "$NET_RC" = 0 ] && printf '%s' "$NET_OUT" | grep -q 'downloaded=1' && [ -s "$_p" ]; then
		# Promote ✘ -> ✓ now (offline rename, carries save + cover). Safe outside the launch window.
		eng_offline --reconcile "$_p"
		ui_msg_timed "Downloaded - it's in $_sys in your library" 3
		return 0
	fi
	if [ "$NET_RC" != 0 ]; then ui_error_ack "$(diagnose "$NET_RC")"
	else
		# rc=0 but no verified file: map the engine's own DLFAIL diagnostic to an actionable cause
		# instead of pointing a device user at a log they can't read.
		_df="$(printf '%s\n' "$NET_OUT" | grep -a '^DLFAIL' | tail -1)"
		case "$_df" in
			*resolve*) ui_error_ack "$_name isn't in your library index - run Refresh library, then retry" ;;
			*verify*)  ui_error_ack "Download didn't verify - try again" ;;
			*)         ui_error_ack "Couldn't download $_name - try again" ;;
		esac
	fi
	return 1
}

gm_queue_add() {    # offline append to the engine's download-queue.txt (SDCARD-relative line, the
	# exact format --download-queue reads); dedup'd so double-taps never double-download.
	_p="$1"; _rel="${_p#"$SDCARD"/}"
	_qf="$PAKDIR/download-queue.txt"
	if [ -f "$_qf" ] && grep -qxF "$_rel" "$_qf" 2>/dev/null; then
		ui_msg_timed "Already queued - run Download queue from the Lodor menu" 3
		return 0
	fi
	if printf '%s\n' "$_rel" >> "$_qf" 2>/dev/null; then
		log "queued for download: $_rel"
		ui_msg_timed "Queued - download it any time from the Lodor menu" 3
	else
		ui_error_ack "Couldn't write the queue - check the SD card"
	fi
	return 0
}

gm_delete() {       # confirm -> engine --evict (offline). 0 = path changed (caller rebuilds).
	_p="$1"; _name="$(basename "$_p")"
	printf 'Delete from this card\nKeep it\n' > "$PICK_LST"
	pick "Delete $_name? Your save data is kept." "CONFIRM"; _drc=$?
	[ "$_drc" = 0 ] || return 1
	[ "$PICK_VAL" = "Delete from this card" ] || return 1
	ui_msg "Deleting $_name..."
	eng_offline --evict "$_p"
	ui_clear
	if [ "$NET_RC" = 0 ] && printf '%s' "$NET_OUT" | grep -q 'evicted=1'; then
		ui_msg_timed "Deleted from card - still in your library to re-download" 3
		return 0
	fi
	ui_error_ack "Couldn't delete $_name - check the SD card"
	return 1
}

gm_sync_save() {    # engine --sync-save for this one ROM; honest per-direction report
	_p="$1"; _name="$(basename "$_p")"
	_require_online || return 1
	ui_msg "Syncing save for $_name..."
	run_net --sync-save "$_p"
	ui_clear
	if [ "$NET_RC" != 0 ]; then ui_error_ack "$(diagnose "$NET_RC")"; return 1; fi
	_ln="$(printf '%s\n' "$NET_OUT" | grep -a '^RESULT pulled=' | tail -1)"
	# reason= (A2) is the engine's honest decision token — match it FIRST so "couldn't reach
	# the server" can never render as "Save already in sync" (the 2026-07-02 Smart Pro field
	# lie: tailscaled was down, every call failed, the old 0/0 glob said all was well). The
	# count-glob cases below keep working against an older engine that emits no reason.
	case "$_ln" in
		*reason=offline*)  ui_error_ack "Couldn't reach your server - check the server or your connection, then retry"; return 1 ;;
		*reason=resolve*)  ui_msg_timed "This game isn't matched to your server library" 4 ;;
		*reason=in-sync*)  ui_msg_timed "Save already in sync" 2 ;;
		*reason=tombstone*) ui_msg_timed "Save was deleted on this device - use Server Saves to bring it back" 3 ;;
		*reason=unpushed-local*)
			if printf '%s' "$_ln" | grep -q 'pushed=1'; then
				ui_msg_timed "Your newer save was uploaded to the server" 3
			else
				ui_error_ack "Your save couldn't upload - it stays safe on this card"
			fi ;;
		*reason=no-server-save*)
			if printf '%s' "$_ln" | grep -q 'pushed=1'; then
				ui_msg_timed "Save uploaded to your server" 3
			else
				ui_msg_timed "No saves for this game yet" 2
			fi ;;
		*pulled=1*pushed=1*) ui_msg_timed "Save synced - newer server copy pulled, yours pushed" 3 ;;
		*pushed=1*)          ui_msg_timed "Save uploaded to your server" 3 ;;
		*pulled=1*)          ui_msg_timed "Newer save pulled from your server" 3 ;;
		*pulled=0*pushed=0*) ui_msg_timed "Save already in sync" 2 ;;
		*)                   ui_msg_timed "${_ln:-Save sync finished - see last-sync.log}" 3 ;;
	esac
	# GHOSTS (task #124): the engine appends ghosts=<N> — server save RECORDS whose bytes are
	# missing/zero. They are already excluded from every pull/restore; surface the count honestly
	# so "why isn't my old save offered?" has a visible answer.
	_gh="$(printf '%s\n' "$_ln" | sed -n 's/.*ghosts=\([0-9][0-9]*\).*/\1/p')"
	if [ -n "$_gh" ] && [ "$_gh" -gt 0 ] 2>/dev/null; then
		ui_msg_timed "$_gh broken save(s) on server - ignored (no data stored)" 3
	fi
	return 0
}

gm_server_saves() { # --list-saves picker (ghost-aware) -> confirm -> --restore-save
	_p="$1"; _name="$(basename "$_p")"
	_require_online || return 1
	ui_msg "Checking server saves..."
	# Same TSV the pre-launch restore prompt parses: <id>\t<date>\t<who>\t<kb>KB[\tCURRENT].
	# The single-field LOCAL= trailer (A3) is dropped by the NF>=2 filter. rc is checked FIRST:
	# an unreachable server (engine exit 3/6, A2) must never render as "No server saves" —
	# that exact conflation cost the 2026-07-02 Smart Pro field session its diagnosis.
	_raw="$("$RUN" --list-saves "$_p" 2>/dev/null)"; _lsrc=$?
	_saves="$(printf '%s\n' "$_raw" | awk -F'\t' 'NF>=2')"
	ui_clear
	if [ "$_lsrc" != 0 ]; then ui_error_ack "$(diagnose "$_lsrc")"; return 1; fi
	if [ -z "$_saves" ]; then ui_msg_timed "No server saves for $_name" 3; return 0; fi
	: > "$PICK_LST"; : > "$GM_IDS"
	TAB="$(printf '\t')"
	printf '%s\n' "$_saves" | while IFS="$TAB" read -r _sid _sdate _swho _ssize _scur; do
		_lbl="$_sdate  -  $_swho  -  $_ssize"
		[ "$_scur" = "CURRENT" ] && _lbl="$_lbl  (on this device)"
		# Ghost-aware belt + braces: the engine already hides ghosts (#63, SplitGhosts); if a
		# 0KB row ever appears anyway, LABEL it unrestorable — selecting it is refused below.
		[ "$_ssize" = "0KB" ] && _lbl="$_lbl  (empty - can't restore)"
		printf '%s\n' "$_lbl" >> "$PICK_LST"
		printf '%s\n' "$_sid" >> "$GM_IDS"
	done
	while :; do
		pick "Server saves - $_name" "RESTORE"; _src=$?
		# render fail here degrades to a plain return: the action menu redraw hits the same
		# renderer and its failure path closes the Game Manager honestly.
		[ "$_src" = 0 ] || return 0
		_sel="$PICK_VAL"
		case "$_sel" in
			*"(empty - can't restore)")
				ui_msg_timed "That save has no data on the server - pick another" 3
				continue ;;
		esac
		_ln="$(grep -n -F -x "$_sel" "$PICK_LST" 2>/dev/null | head -1 | cut -d: -f1)"
		[ -n "$_ln" ] || return 0
		_sid="$(sed -n "${_ln}p" "$GM_IDS" 2>/dev/null)"
		[ -n "$_sid" ] || return 0
		# Confirm before overwriting the local save (the engine still preserves the current
		# save first: pushed to the timeline, or staged for later upload when offline).
		printf 'Restore this save\nCancel\n' > "$PICK_LST"
		pick "Restore save from $_sel?" "CONFIRM"; _crc=$?
		[ "$_crc" = 0 ] && [ "$PICK_VAL" = "Restore this save" ] || return 0
		ui_msg "Restoring save..."
		run_net --restore-save "$_p" "$_sid"
		ui_clear
		if [ "$NET_RC" = 0 ] && printf '%s' "$NET_OUT" | grep -q 'restored=1'; then
			# A Tool can't safely relaunch the game (that would bypass NextUI's switcher/recents
			# bookkeeping) — orient the user to the library instead of leaving "now what?".
			if printf '%s' "$NET_OUT" | grep -q 'staged=[1-9]'; then
				ui_msg_timed "Save restored - launch it from the library. Your previous save is queued to upload" 4
			else
				ui_msg_timed "Save restored - launch it from the library" 3
			fi
		elif printf '%s' "$NET_OUT" | grep -q 'reason=ghost'; then
			# engine-side refusal (a ghost slipped past the listing): never fake a restore
			ui_error_ack "That save has no data on the server - can't restore"
		elif [ "$NET_RC" != 0 ]; then
			ui_error_ack "$(diagnose "$NET_RC")"
		else
			ui_error_ack "Restore failed - try again"
		fi
		return 0
	done
}

gm_actions() {      # per-game action menu. Returns 9 ONLY on renderer failure (aborts the manager).
	_gpath="$1"
	while :; do
		[ -f "$_gpath" ] || return 0   # renamed/evicted under us -> back to the (rebuilt) game list
		_g="$(basename "$_gpath")"
		: > "$PICK_LST"
		if [ -s "$_gpath" ]; then printf 'Delete from card\n' >> "$PICK_LST"
		else printf 'Download now\nAdd to download queue\n' >> "$PICK_LST"; fi
		printf 'Sync save now\nServer saves\nDetails\n' >> "$PICK_LST"
		pick "$_g" "SELECT"; _arc=$?
		case "$_arc" in
			0) : ;;
			2|3) return 0 ;;
			*) ui_msg_timed "Menu renderer failed - closing Game Manager" 3; return 9 ;;
		esac
		case "$PICK_VAL" in
			"Download now")           gm_download "$_gpath" && return 0 ;;   # name flipped ✘->✓: rebuild list
			"Add to download queue")  gm_queue_add "$_gpath" ;;
			"Delete from card")       gm_delete   "$_gpath" && return 0 ;;   # name flipped ✓->✘: rebuild list
			"Sync save now")          gm_sync_save "$_gpath" ;;
			"Server saves")           gm_server_saves "$_gpath" ;;
			"Details")                gm_details "$_gpath" ;;
		esac
	done
}

gm_games() {        # game picker for one system folder. Returns 9 ONLY on renderer failure.
	_sys="$1"; _sysdir="$SDCARD/Roms/$_sys"
	while :; do
		: > "$PICK_LST"
		find "$_sysdir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r _f; do
			_b="$(basename "$_f")"
			case "$_b" in .*|map.txt) continue ;; esac
			printf '%s\n' "$_b" >> "$PICK_LST"
		done
		if [ ! -s "$PICK_LST" ]; then ui_msg_timed "No games in $_sys yet" 3; return 0; fi
		pick "$_sys" "MANAGE"; _grc=$?
		case "$_grc" in
			0) : ;;
			2|3) return 0 ;;
			*) ui_msg_timed "Menu renderer failed - closing Game Manager" 3; return 9 ;;
		esac
		_gar=0; gm_actions "$_sysdir/$PICK_VAL" || _gar=$?
		[ "$_gar" = 9 ] && return 9
	done
}

# do_search_library (parity item #4) — whole-catalog search with ZERO network: the on-card stub
# mirror under Roms/ IS the whole catalog, so a filename scan reaches every game (downloaded or
# cloud-stub). minui-keyboard -> case-insensitive substring -> results list -> the SAME gm_actions
# flow (download / queue / delete / saves / details). Capped like LodorOS's root search.
SEARCH_IDS="/tmp/lodor-search-ids"
do_search_library() {
	kb "Search your library" ""; _rc=$?
	[ "$_rc" = 0 ] || return 0
	_q="$(printf '%s' "$KB_VAL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	if [ -z "$_q" ]; then ui_msg_timed "Type part of a game name to search" 3; return 0; fi
	while :; do
		: > "$PICK_LST"; : > "$SEARCH_IDS"
		# One awk pass (no per-file forks): match the BASENAME only (matching the whole path would
		# make a system-name query flood-match its every game), skip the GM folder / hidden / map.txt.
		find "$SDCARD/Roms" -mindepth 2 -maxdepth 2 -type f 2>/dev/null | sort | \
		awk -v q="$_q" -v gmtag="($GM_TAG)" -v cttag="($CT_TAG)" -v max=200 -v lst="$PICK_LST" -v ids="$SEARCH_IDS" '
			BEGIN { lq = tolower(q) }
			{
				k = split($0, seg, "/")
				b = seg[k]; d = seg[k-1]
				if (index(d, gmtag) > 0 || index(d, cttag) > 0) next
				if (substr(d, 1, 1) == ".") next
				if (substr(b, 1, 1) == "." || b == "map.txt") next
				if (index(tolower(b), lq) == 0) next
				n++
				if (n > max) { more = 1; next }
				print b "  -  " d >> lst
				print $0 >> ids
			}
			END { if (more) exit 200 }'
		_trunc=$?
		if [ ! -s "$PICK_LST" ]; then ui_msg_timed "No games match \"$_q\"" 3; return 0; fi
		_ttl="Search: $_q"
		[ "$_trunc" = 200 ] && _ttl="Search: $_q (first 200)"
		pick "$_ttl" "MANAGE"; _src=$?
		case "$_src" in
			0) : ;;
			2|3) return 0 ;;
			*) ui_msg_timed "Menu renderer failed - closing search" 3; return 9 ;;
		esac
		_ln="$(grep -n -F -x "$PICK_VAL" "$PICK_LST" 2>/dev/null | head -1 | cut -d: -f1)"
		[ -n "$_ln" ] || return 0
		_gp="$(sed -n "${_ln}p" "$SEARCH_IDS" 2>/dev/null)"
		[ -n "$_gp" ] || return 0
		_sar=0; gm_actions "$_gp" || _sar=$?
		[ "$_sar" = 9 ] && return 9
		# loop: rebuild the results (an action may have flipped the ✘/✓ marker = renamed the file)
	done
}

do_game_manager() { # system picker (top level). Browsing is offline-capable; net actions gate themselves.
	while :; do
		: > "$PICK_LST"
		printf 'Search library\n' >> "$PICK_LST"
		find "$SDCARD/Roms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r _d; do
			_b="$(basename "$_d")"
			# skip hidden dirs AND the Game Manager's own root-entry folder (it is a launcher
			# affordance, not a game library — managing it from inside itself makes no sense).
			case "$_b" in .*|*"($GM_TAG)"|*"($CT_TAG)") continue ;; esac
			printf '%s\n' "$_b" >> "$PICK_LST"
		done
		# an empty card = only the search row would remain, and there is nothing to search either
		if [ "$(count_lines "$PICK_LST")" -le 1 ] 2>/dev/null; then
			ui_msg_timed "No game library on this card yet - run Refresh library first" 4
			return 0
		fi
		pick "Game Manager" "OPEN"; _grc=$?
		case "$_grc" in
			0) : ;;
			2|3) return 0 ;;
			*) ui_msg_timed "Menu renderer failed - closing Game Manager" 3; return 0 ;;
		esac
		_ggr=0
		if [ "$PICK_VAL" = "Search library" ]; then do_search_library || _ggr=$?
		else gm_games "$PICK_VAL" || _ggr=$?; fi
		[ "$_ggr" = 9 ] && return 0
	done
}

# --------------------------------------------------------------------------------------------------
# Menu. Drawn by minui-list (proven). If minui-list is missing OR fails to render, degrade HONESTLY to
# a one-shot Sync now instead of dying with a blank screen.
# --------------------------------------------------------------------------------------------------
run_menu() {
	while :; do
		rm -f "$MENU_OUT" "$MENU_LST"
		# Each line is a thin shell over ONE engine mode. RetroAchievements is intentionally NOT here:
		# NextUI owns RA natively (its own login/creds in config.c/ra_auth.c) — the engine's --ra-login
		# stays a LodorOS-only path so two RA configs never fight (decision 2026-06-30). The coexist
		# line shows the live mirror_mode so the toggle's effect is honest. "Setup / Re-pair" re-runs
		# the onboarding wizard so a mis-paired / server-changed device is never stranded.
		_cx="$(get_mirror_mode)"
		case "$_cx" in
			separate) _cxlbl="RomM games: Separate folders" ;;
			*)        _cxlbl="RomM games: Mixed into your folders" ;;
		esac
		_bc="$(get_fetch_covers)"
		case "$_bc" in
			on)  _bclbl="Box art: All covers (on refresh)" ;;
			*)   _bclbl="Box art: Downloaded games only" ;;
		esac
		# All "(N)" counts + the active-profile label are LOCAL file reads (count_lines /
		# active_profile_label) — drawing the menu never touches the network.
		_np="$(count_lines "$PAKDIR/pending-saves.txt")"
		_nq="$(count_lines "$PAKDIR/download-queue.txt")"
		_ulbl="$(active_profile_label)"
		_free="$(sd_free)"
		# update badge: a LOCAL settings.conf read + one local --version exec, no network. The
		# row self-retires once the Pak Store installed the version it names.
		_uav="$(sed -n 's/^update_available=//p' "$SETTINGS" 2>/dev/null | head -1)"
		[ -n "$_uav" ] && [ "$_uav" = "$(current_engine_version)" ] && _uav=""
		{
			# PAIRING-EXPIRED banner (task #124): flagged by any engine rc=6 (menu action, hook,
			# daemon-adjacent paths writing the same flag). Top row, one press into the re-pair
			# wizard; cleared automatically by the first engine call that succeeds again.
			[ -f "$PAIR_FLAG" ] && printf '! Pairing expired - re-pair\n'
			printf 'Sync now\n'
			# saves parked offline are never invisible (parity item #2); row only when real
			[ "$_np" -gt 0 ] 2>/dev/null && printf 'Pending saves (%s) - upload now\n' "$_np"
			printf 'Refresh library (full, slow)\n'
			printf 'Game Manager\n'
			printf 'Search library\n'
			# live queue count (parity item #3); an empty queue draws no dead row
			[ "$_nq" -gt 0 ] 2>/dev/null && printf 'Download queue (%s)\n' "$_nq"
			printf 'Download BIOS\n'
			printf 'Recent activity\n'
			# a found update surfaces at the top of the housekeeping block; install happens in
			# the Pak Store (store lane — Lodor never swaps its own pak on NextUI)
			[ -n "$_uav" ] && printf 'Update available (%s) - Pak Store\n' "$_uav"
			printf 'Switch user (%s)\n' "$_ulbl"
			printf '%s\n' "$_bclbl"
			printf '%s\n' "$_cxlbl"
			printf 'Check for updates\n'
			printf 'Setup / Re-pair\n'
			printf 'Remove Lodor from this card\n'
			if ts_available; then
				printf 'Tailscale status\n'
				printf 'Tailscale: Reconnect\n'
				printf 'Tailscale: Reset & forget\n'
			fi
		} > "$MENU_LST"

		killall minui-presenter >/dev/null 2>&1 || true
		"$LISTBIN" --disable-auto-sleep --file "$MENU_LST" --format text \
			--title "Lodor${_free:+ - $_free free}" --confirm-text "OPEN" --cancel-text "EXIT" \
			--write-location "$MENU_OUT"
		lrc=$?
		case "$lrc" in
			0) : ;;              # selection -> handle below
			2|3) return 0 ;;     # B / menu -> clean Tool exit
			*) return "$lrc" ;;  # render failure -> degrade
		esac

		sel="$(cat "$MENU_OUT" 2>/dev/null)"
		case "$sel" in
			"! Pairing expired"*)   do_reonboard ;;
			"Sync now")             do_sync_now ;;
			"Pending saves ("*)     do_push_pending ;;
			"Refresh library"*)     do_refresh_library ;;
			"Game Manager")         do_game_manager ;;
			"Search library")       do_search_library ;;
			"Download queue"*)      do_download_queue ;;
			"Download BIOS")        do_download_bios ;;
			"Recent activity")      do_sync_feed ;;
			"Switch user ("*)       do_switch_user ;;
			"Box art:"*)            toggle_fetch_covers "$_bc" ;;
			"Update available ("*)  do_check_updates ;;
			"Check for updates")    do_check_updates ;;
			"Setup / Re-pair")      do_reonboard ;;
			"Remove Lodor from"*)   do_uninstall_lodor ;;
			"Tailscale status")     do_ts_status ;;
			"Tailscale: Reconnect") do_ts_reconnect ;;
			"Tailscale: Reset & forget") do_ts_reset ;;
			"RomM games:"*)         toggle_coexist "$_cx" ;;
			"")                     return 0 ;;
			*)                      return 0 ;;
		esac
	done
}

# ==================================================================================================
# ENTRY / DISPATCH.
#   NOT configured -> onboarding wizard (write config.json via the engine). If the user cancels or the
#     flow fails, we exit honestly (no half-built client on an unpaired device).
#   Configured     -> first-run hook self-install + background sync daemon, then the Tools menu.
# The configured check is creds_present (the lib's single source of truth: config.json present AND
# carrying a "token"). This is the SAME check the former Lodor Setup.pak used.
# ==================================================================================================
if ! creds_present; then
	log "state: not configured -> onboarding wizard"
	# ORIENTATION (#4): a real first page instead of a 3s flash — what Lodor will do (the Go
	# wizard's welcome copy), then an explicit choice. "Not now" / B exits cleanly and asks
	# again next open; nothing on the card changes until the user opts in. Info rows redraw.
	if [ -x "$LISTBIN" ]; then
		_wl_go=0
		while :; do
			{
				printf 'Your whole RomM library appears on this device\n'
				printf 'Games download when you launch them\n'
				printf 'Saves sync automatically between your devices\n'
				printf 'Set up now\n'
				printf 'Not now\n'
			} > "$PICK_LST"
			pick "Lodor - connect to your RomM server" "SELECT"; _wl_rc=$?
			case "$_wl_rc" in
				0)
					case "$PICK_VAL" in
						"Set up now") _wl_go=1; break ;;
						"Not now")    break ;;
						*)            continue ;;   # info row picked -> redraw the page
					esac ;;
				2|3) break ;;                       # B / MENU -> clean exit, ask again next open
				*)   _wl_go=1; break ;;             # render failure -> the wizard degrades honestly itself
			esac
		done
		if [ "$_wl_go" != 1 ]; then
			log "onboarding: welcome declined (Not now / back) - exiting until next open"
			ui_clear
			exit 0
		fi
	fi
	run_wizard || true
	if ! creds_present; then
		log "onboarding: not completed (cancelled or failed) - exiting until next open"
		ui_clear
		exit 0
	fi
	log "onboarding: config written -> continuing to client"
fi

# --------------------------------------------------------------------------------------------------
# Configured. Make the coexist mode explicit (C2 consent point — silent merge for clean/fresh cards,
# a one-time prompt for separate-era cards), then first-run self-install: wire the launch hooks +
# start the background sync daemon. Idempotent.
# --------------------------------------------------------------------------------------------------
ensure_mirror_mode

HOOKS_DST=""
[ -n "${SDCARD_PATH:-}" ] && [ -n "${PLATFORM:-}" ] && HOOKS_DST="$SDCARD_PATH/.userdata/$PLATFORM/.hooks"

needs_wiring=0
hooks_first=1   # TRUE first install (no hook file exists at all) vs a silent build-update refresh
if [ -n "$HOOKS_DST" ] && [ -d "$PAKDIR/hooks" ]; then
	for _hd in pre-launch.d post-launch.d boot.d; do
		for _src in "$PAKDIR/hooks/$_hd/"*; do
			[ -f "$_src" ] || continue
			_dst="$HOOKS_DST/$_hd/$(basename "$_src")"
			[ -f "$_dst" ] && hooks_first=0
			cmp -s "$_src" "$_dst" 2>/dev/null || needs_wiring=1
		done
	done
fi

if [ "$needs_wiring" = 1 ]; then
	# QUIET HEAL (B2, the root-entry "crash" fix): a build update re-syncs drifted hooks
	# SILENTLY — the old unconditional "Installing Lodor..." painted mid-selection on every
	# update and read as a malfunction. Messages only on a TRUE first install; failures
	# stay loud on both paths.
	if [ "$hooks_first" = 1 ]; then
		ui_msg "Installing Lodor..."
		ui_msg "Wiring auto-sync hooks..."
	fi
	wired_ok=1
	for _hd in pre-launch.d post-launch.d boot.d; do
		mkdir -p "$HOOKS_DST/$_hd"
		for _src in "$PAKDIR/hooks/$_hd/"*; do
			[ -f "$_src" ] || continue
			_dst="$HOOKS_DST/$_hd/$(basename "$_src")"
			cp -f "$_src" "$_dst" 2>/dev/null && chmod +x "$_dst" 2>/dev/null
			cmp -s "$_src" "$_dst" 2>/dev/null || wired_ok=0
		done
	done
	if [ "$wired_ok" != 1 ]; then
		ui_error_ack "Couldn't wire auto-sync hooks - check the SD card, then retry"
		exit 1
	fi
	log "hooks self-installed + verified (first_install=$hooks_first)"

	[ "$hooks_first" = 1 ] && ui_msg "Starting background sync..."
	if pgrep -f "romm-syncd" >/dev/null 2>&1; then
		log "daemon already running"
	elif [ -x "$PAKDIR/bin/romm-syncd" ]; then
		if command -v setsid >/dev/null 2>&1; then
			setsid "$PAKDIR/bin/romm-syncd" </dev/null >/dev/null 2>&1 &
		else
			"$PAKDIR/bin/romm-syncd" </dev/null >/dev/null 2>&1 &
		fi
		_k=0; while ! pgrep -f "romm-syncd" >/dev/null 2>&1 && [ "$_k" -lt 20 ]; do sleep 0.1; _k=$((_k + 1)); done
		if pgrep -f "romm-syncd" >/dev/null 2>&1; then
			log "daemon started"
		else
			log "WARN: could not confirm romm-syncd started; boot.d hook will start it next boot"
		fi
	fi
	if [ "$hooks_first" = 1 ]; then
		ui_msg_timed "Lodor installed." 2
		ui_clear
	fi
fi

# Game Manager ROOT ENTRY self-heal moved EARLY (task #131): gm_root_selfheal now runs right after
# the GM definitions, BEFORE the onboarding gate — see the comment there for why (a cancelled wizard
# session used to leave the root entry uninstalled until the first fully-configured client run).

maybe_seed_library

# --------------------------------------------------------------------------------------------------
# --game-manager mode (the ROOT ENTRY path): everything above ran identically — onboarding gate,
# hook + root-entry self-install, daemon, first-run seed — then we open the Game Manager DIRECTLY
# instead of the Tools menu. Same do_game_manager the Tools menu dispatches to: one code path.
# --------------------------------------------------------------------------------------------------
if [ "$GM_MODE" = 1 ]; then
	if [ -x "$LISTBIN" ]; then
		ui_clear   # replace the dispatcher's "Opening Game Manager..." first-paint (B2)
		do_game_manager
	else
		log "minui-list missing - Game Manager cannot draw (root entry)"
		ui_msg_timed "Game Manager needs the menu renderer - it is missing from Lodor.pak" 4
	fi
	# B3: the root-entry selection put the GM dummy into NextUI recents/switcher — remove it
	# (and any Continue dummy) while the launcher is still dead.
	scrub_recents
	ui_clear
	exit 0
fi

if [ -x "$LISTBIN" ]; then
	run_menu; mrc=$?
	if [ "$mrc" != 0 ]; then
		log "minui-list failed to render (rc=$mrc) - degrading to one-shot Sync now"
		ui_msg_timed "Lodor menu unavailable on this device - running Sync now instead." 4
		do_sync_now
	fi
else
	log "minui-list missing - degrading to one-shot Sync now"
	do_sync_now
fi

ui_clear
exit 0

# --------------------------------------------------------------------------------------------------
# ENGINE COORDINATION NOTE (mirror_mode): this Tool writes the coexist setting to
# $LODOR_CFG_DIR/settings.conf as `mirror_mode=separate|merge` (a deliberately separate key=value
# file, NOT config.json, so a UI toggle can never corrupt the token-bearing config.json). The engine
# reads settings.conf from its CWD (LODOR_CFG_DIR); absent, it defaults to MERGE on NextUI (C2) —
# EXCEPT that a card whose directory_mappings still carry the separate layout holds separate until
# an explicit merge is written (mode flips are prompt-only; ensure_mirror_mode above is the pak's
# consent point, so a configured card always ends up with an explicit value).
# --------------------------------------------------------------------------------------------------
