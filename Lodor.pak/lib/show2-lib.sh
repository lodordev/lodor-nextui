# shellcheck shell=sh
# (sourced library — no shebang; the sourcing script sets the shell)
# show2-lib.sh (NextUI / tg5040) — shared on-screen presenter helpers (stock show2.elf).
#
# HOST RENDERER ONLY. Draws status text + a progress bar; ALL logic stays in the Lodor engine.
# Sourced by launch.sh (the Tool) and by the pre-launch fetch hook so there is ONE show2 driver,
# not two divergent copies. show2.elf is stock on tg5040 (workspace/all/show2 -> SYSTEM bin, on PATH).
#
# Honesty rules (feedback_no_fake_ui_state): a step is only shown done when it is verified done; the
# daemon is only treated as "up" once its FIFO exists and the pid is alive; errors are persistent and
# readable (generous timeout — show2 never polls input), never a sub-second blip; if show2 is absent
# (very old firmware) we degrade to log-only and never hang.
#
# Public API:
#   ui_begin <text>            start the daemon (confirms it is really up; sets SHOW2_OK)
#   ui_set   <text> [progress] update line / bar (no-op if daemon not up)
#   ui_stop                    tear the daemon down cleanly (idempotent)
#   ui_simple <bgcolor> <text> <timeout>   one-shot blocking screen (no daemon)
#   ui_error <line>            stop daemon, then a persistent red screen (12s) + legacy fallback
#
# Tunables (export before sourcing; all optional):
#   SHOW2_LOGO  image passed to show2 (need NOT exist; show2 tolerates a missing file, draws text-only)
#   SHOW2_BG    default background color (hex), default 0x0d1b2a
#   SHOW2_LOGFN name of a one-arg shell function used to log a line (default: none)

SHOW2_BIN="$(command -v show2.elf 2>/dev/null || true)"
SHOW2_LEGACY="$(command -v show.elf 2>/dev/null || true)"
SHOW2_FIFO="/tmp/show2.fifo"
SHOW2_PID=""
SHOW2_OK=0
: "${SHOW2_LOGO:=}"
: "${SHOW2_BG:=0x0d1b2a}"

_s2log() { [ -n "${SHOW2_LOGFN:-}" ] && command -v "$SHOW2_LOGFN" >/dev/null 2>&1 && "$SHOW2_LOGFN" "$1"; return 0; }

# _fb_settle — guarantee a CLEAN framebuffer/display handoff before this Tool launches a
# show2.elf display owner. lodor-picker (NextUI GFX/SDL) and show2.elf (raw SDL) are two
# SEPARATE display-owning binaries; cycling them in one Tool session can fault the tg5040
# (H700) display pipeline if the previous owner has not fully released /dev/fb0. So: reap
# any stray show2 daemon, clear its FIFO, and give the prior SDL owner (the picker) a beat
# to release the display before we grab it. Host-renderer concern only — never the engine.
# STAGED 2026-06-27 (Lodor NextUI): suspected root cause of the "select-any-item crash".
# Needs on-device confirmation; LODOR_NO_SHOW2=1 below is the A/B lever to prove it.
_fb_settle() {
	pkill -f "show2.elf" 2>/dev/null || killall show2.elf 2>/dev/null || true
	rm -f "$SHOW2_FIFO" 2>/dev/null
	sleep "${LODOR_FB_SETTLE:-0.4}"
	return 0
}

# ui_begin <text> — launch the daemon and CONFIRM it came up (FIFO present + pid alive) before
# claiming the UI works. Never blocks longer than ~2s waiting.
ui_begin() {
	SHOW2_OK=0; SHOW2_PID=""
	[ "${LODOR_NO_SHOW2:-0}" = 1 ] && { _s2log "show2 suppressed (LODOR_NO_SHOW2) — log-only: $1"; return 0; }
	[ -n "$SHOW2_BIN" ] || { _s2log "show2.elf not on PATH — UI degraded to log-only"; return 0; }
	_fb_settle
	"$SHOW2_BIN" --mode=daemon --image="$SHOW2_LOGO" --bgcolor="$SHOW2_BG" --fontcolor=0xffffff \
	            --text="$1" --fontsize=22 --texty=78 --progressy=88 >/dev/null 2>&1 &
	SHOW2_PID=$!
	_i=0
	while [ "$_i" -lt 20 ]; do
		if [ -p "$SHOW2_FIFO" ] && kill -0 "$SHOW2_PID" 2>/dev/null; then SHOW2_OK=1; break; fi
		kill -0 "$SHOW2_PID" 2>/dev/null || break
		sleep 0.1; _i=$((_i + 1))
	done
	[ "$SHOW2_OK" = 1 ] || _s2log "show2 daemon did not come up — UI degraded to log-only"
	return 0
}

# ui_set <text> [progress] — update line/bar; guarded so a dead daemon never hangs the caller.
ui_set() {
	_s2log "$1"
	[ "$SHOW2_OK" = 1 ] && kill -0 "$SHOW2_PID" 2>/dev/null && [ -p "$SHOW2_FIFO" ] || return 0
	printf 'TEXT:%s\n' "$1" > "$SHOW2_FIFO" 2>/dev/null
	[ -n "${2:-}" ] && printf 'PROGRESS:%s\n' "$2" > "$SHOW2_FIFO" 2>/dev/null
	return 0
}

# ui_stop — tear the daemon down cleanly (idempotent). Frees the framebuffer for the next presenter
# (e.g. lodor-picker) or the emulator.
ui_stop() {
	if [ "$SHOW2_OK" = 1 ] && kill -0 "$SHOW2_PID" 2>/dev/null; then
		[ -p "$SHOW2_FIFO" ] && printf 'QUIT\n' > "$SHOW2_FIFO" 2>/dev/null
		_j=0; while kill -0 "$SHOW2_PID" 2>/dev/null && [ "$_j" -lt 10 ]; do sleep 0.1; _j=$((_j + 1)); done
		kill -9 "$SHOW2_PID" 2>/dev/null
	fi
	SHOW2_OK=0; SHOW2_PID=""
	rm -f "$SHOW2_FIFO" 2>/dev/null
	return 0
}

# ui_simple <bgcolor> <text> <timeout> — one-shot BLOCKING screen (no daemon). Used for short honest
# messages ("Downloaded", "Restored", failures). Stops any running daemon first.
ui_simple() {
	ui_stop
	_s2log "$2"
	[ "${LODOR_NO_SHOW2:-0}" = 1 ] && return 0
	if [ -n "$SHOW2_BIN" ]; then
		_fb_settle
		"$SHOW2_BIN" --mode=simple --image="$SHOW2_LOGO" --bgcolor="$1" --fontcolor=0xffffff \
		            --text="$2" --fontsize=20 --texty=70 --timeout="$3" >/dev/null 2>&1
	elif [ -n "$SHOW2_LEGACY" ] && [ -n "$SHOW2_LOGO" ] && [ -f "$SHOW2_LOGO" ]; then
		"$SHOW2_LEGACY" "$SHOW2_LOGO" "$3" >/dev/null 2>&1
	fi
	return 0
}

# ui_error <line> — persistent, readable error on a red screen (12s).
ui_error() { _s2log "ERROR: $1"; ui_simple 0x3a0d0d "$1" 12; return 0; }
