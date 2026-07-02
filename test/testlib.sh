# testlib.sh — sourced INTO launch.sh via the LODOR_TEST_LIB hook (right after romm-sync-lib.sh),
# so these definitions override ONLY the hardware-facing helpers. Everything else — the wizard,
# the menu dispatch, kb/pick, run_net/eng_offline, tailscale_mark_tier1 / ts_reset /
# _ts_state_restore (pure file ops), creds_present, lodor_migrate_cfg — stays REAL and under test.
#
# Scripting surface (all under $LODOR_SIM_DIR):
#   wifi           file containing `up` or `down`  -> _radio_ready / _have_up / _have_ip
#   q/tsurl.q      queue of login URLs             -> tailscale_up_interactive (empty line = no URL)
#   q/tsstatus.q   queue of connected|pending|stopped -> tailscale_status (sticky last)
# shellcheck shell=sh
# shellcheck disable=SC2034  # some vars are consumed by the sourcing script, not here

LODOR_SIM_DIR="${LODOR_SIM_DIR:?testlib sourced without LODOR_SIM_DIR}"

_sim_trace() { printf 'TESTLIB %s\n' "$1" >> "$LODOR_SIM_DIR/trace.log" 2>/dev/null; }
_sim_wifi()  { cat "$LODOR_SIM_DIR/wifi" 2>/dev/null || echo down; }

# --- Wi-Fi link probes: scripted, never /sys ----------------------------------
_have_up()     { [ "$(_sim_wifi)" = up ]; }
_have_ip()     { [ "$(_sim_wifi)" = up ]; }
_wlan_ip()     { [ "$(_sim_wifi)" = up ] && echo 10.0.0.42; }
_radio_ready() { _have_up; }
_radio_wait()  { _radio_ready; }   # instant — loop counts are covered by sticky queues + timeout

# --- host-state side effects that must NOT touch the CI container -------------
_ensure_resolv()        { return 0; }   # real one may write /etc/resolv.conf
wifi_ensure_reachable() { return 0; }   # real one nc-probes the RomM host
set_clock()             { return 0; }   # real one runs ntpd / date -s
is_charging()           { return 0; }

# --- Tailscale process control: scripted (the daemon/CLI never run off-device) -
tailscale_up() { _sim_trace "tailscale_up"; return 0; }
tailscale_up_interactive() {
	# Device-faithful side effect kept: the real function's first act is _ts_state_restore,
	# whose `mkdir -p $TS_STATEDIR` is exactly what collided with launch.sh's QR statefile
	# (trap found 2026-07-02). The pure-file helper is real; only the daemon spawn is scripted.
	_ts_state_restore
	_u="$(simq tsurl 2>/dev/null)" || _u=""
	_sim_trace "tailscale_up_interactive -> '$_u'"
	echo "$_u"
	return 0
}
tailscale_status() {
	_s="$(simq tsstatus 2>/dev/null)" || _s=stopped
	echo "$_s"
}
tailscale_ip()   { echo 100.64.0.9; }
tailscale_down() { _sim_trace "tailscale_down"; return 0; }
# tailscale_reconnect — scripted like the others (the REAL restart logic is exercised by the
# tslib driver scenarios, where pidof/killall are sandbox-safe; running it here would let the
# lib's host-global pidof find the CI box's own tailscaled). Outcome keys off the tsstatus
# queue: connected -> success token, nologin -> no-login, anything else -> not-running.
tailscale_reconnect() {
	_s="$(simq tsstatus 2>/dev/null)" || _s=stopped
	_sim_trace "tailscale_reconnect (scripted status=$_s)"
	case "$_s" in
		connected) echo "connected:100.64.0.9"; return 0 ;;
		nologin)   echo "no-login"; return 1 ;;
		*)         echo "not-running"; return 1 ;;
	esac
}

_sim_trace "loaded (wifi=$(_sim_wifi))"
