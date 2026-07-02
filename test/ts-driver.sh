#!/bin/sh
# ts-driver.sh — step-scripted driver for the REAL tailscale-lib.sh (invoke tslib).
#
# The wizard scenarios stub tailscale_up/…_interactive entirely (testlib.sh) because the
# wizard's UI flow is what they test. THIS driver is the opposite: it sources the shipped
# lib and exercises the real daemon bring-up logic (socket wait, dead-vs-slow daemon
# distinction, reuse-not-duplicate) against a SCRIPTED fake tailscaled (tsdaemon directive).
# Only one seam is overridden: _ts_sock_present becomes a plain-file probe, because a shell
# script cannot create a unix socket — the wait/reuse code paths themselves stay REAL.
#
# Steps come one per line from $LODOR_SIM_DIR/tssteps (tsdrv directive):
#   wait=<secs>   set TS_SOCK_WAIT_SECS for subsequent calls
#   up            call tailscale_up            -> trace "TSDRV up rc=<n>"
#   alive         is a daemon running?         -> trace "TSDRV daemon alive=<0|1>"
#   count         how many fake daemons exist  -> trace "TSDRV daemons=<n>"
#   down          call tailscale_down          -> trace "TSDRV down rc=<n>"
#   tier1up       call lodor_tier1_up (task #134 preamble) -> trace "TSDRV tier1up rc=<n>"
#   reconnect     call tailscale_reconnect     -> trace "TSDRV reconnect rc=<n> tok=<token>"
set -u

SDCARD="${SDCARD_PATH:?}"
PLAT="${PLATFORM:?}"
ROMM_PAK_DIR="$SDCARD/Tools/$PLAT/Lodor.pak"
LODOR_CFG_DIR="${LODOR_CFG_DIR:-$SDCARD/.userdata/shared/Lodor}"
: "${TS_SOCK:?tslib invoke must export a sandbox-scoped TS_SOCK}"
: "${TS_STATEDIR:?tslib invoke must export a sandbox-scoped TS_STATEDIR}"

# Source the FULL shipped lib pair via romm-sync-lib.sh (it sources tailscale-lib.sh itself),
# so the tier-1 preamble helper (lodor_tier1_up) is under test alongside the bring-up logic.
# shellcheck source=../Lodor.pak/lib/romm-sync-lib.sh
. "$ROMM_PAK_DIR/lib/romm-sync-lib.sh"

# THE seam: the fake daemon touches a plain file where the real one binds a unix socket.
# (Invoked indirectly by the sourced lib — hence the SC2329 waiver.)
# shellcheck disable=SC2329
_ts_sock_present() { [ -e "$TS_SOCK" ]; }

# The lib's pidof fallback is HOST-GLOBAL — on a dev box it finds the box's own real
# tailscaled (it did, on panther) and the driver ends up waiting on a daemon it never
# started. TS_DAEMON_PID carries the reuse logic actually under test; neutralize only
# the global lookup. (Also invoked indirectly, via command -v inside the lib.)
# shellcheck disable=SC2329
pidof() { return 1; }

trace() { printf 'TSDRV %s\n' "$1" >> "${LODOR_SIM_DIR:?}/trace.log" 2>/dev/null; }

# NB: the pidof fallback in _ts_running_pid cannot see the fake daemon (it is a sh script,
# so its process name is the shell) — TS_DAEMON_PID carries reuse across calls, which is
# exactly the on-device shape too (retries happen inside one sourcing shell).
STEPS="${LODOR_SIM_DIR:?}/tssteps"
[ -f "$STEPS" ] || { trace "no tssteps file"; exit 2; }
while IFS= read -r step || [ -n "$step" ]; do
	case "$step" in
		''|'#'*) ;;
		wait=*) TS_SOCK_WAIT_SECS="${step#wait=}" ;;
		up)     tailscale_up; trace "up rc=$?" ;;
		alive)
			if [ -n "$(_ts_running_pid)" ]; then trace "daemon alive=1"; else trace "daemon alive=0"; fi ;;
		count)  trace "daemons=$(pgrep -fc "$TS_BIN_DIR/tailscaled" 2>/dev/null || echo 0)" ;;
		down)   tailscale_down; trace "down rc=$?" ;;
		tier1up) lodor_tier1_up; trace "tier1up rc=$?" ;;
		reconnect)
			_tok="$(tailscale_reconnect)"; _trc=$?
			trace "reconnect rc=$_trc tok=$_tok" ;;
		*)      trace "UNKNOWN STEP '$step'"; exit 2 ;;
	esac
done < "$STEPS"
exit 0
