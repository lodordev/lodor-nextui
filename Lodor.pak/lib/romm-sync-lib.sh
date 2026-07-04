# shellcheck shell=sh
# (sourced library — no shebang; the sourcing script sets the shell)
# romm-sync-lib.sh (NextUI / tg5040) — reuse-only Wi-Fi orchestration for the Lodor RomM sync layer.
#
# NextUI OWNS Wi-Fi: the user enables/configures it in NextUI Settings. This lib therefore NEVER
# brings the radio up, never runs wpa_supplicant/udhcpc, never powers it off. It RIDES the existing
# connection — it checks wlan0 has link + an IPv4 lease and proceeds, or fails honestly telling the
# user to enable Wi-Fi in NextUI. The pure-Go (CGO-free) engine's resolver needs /etc/resolv.conf, so
# _ensure_resolv is preserved. A coordination mutex is kept so the launch hooks, the boot daemon, and
# the Tool never run two transfers at once (coordination only — it never touches radio power).
#
# Sourced by: launch.sh (Tool), bin/romm-syncd (boot daemon), and the launch hooks (via bin/romm-run).
# Every function returns 0/non-0 and never calls `exit` (callers decide).

# --- paths (NextUI env or standalone) ----------------------------------------
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-tg5040}"
ROMM_PAK_DIR="$SDCARD/Tools/$PLAT/Lodor.pak"
export LODOR_PAK_DIR="$ROMM_PAK_DIR"
SYNC_BIN="$ROMM_PAK_DIR/lodor-sync"

# --- config home (NextUI SHARED userdata, NOT the pak dir) --------------------
# Decision 2026-06-30: config.json / settings.conf / active-profile.txt live under
# $SHARED_USERDATA_PATH (= $SDCARD/.userdata/shared on NextUI) so the RomM token + UI toggles
# survive a pak reinstall and are shared across NextUI profiles. The engine reads all three
# CWD-relative, so every caller cd's into LODOR_CFG_DIR before exec. Engine STATE
# (catalog-index.json / pending-saves.txt / download-queue.txt) still follows LODOR_PAK_DIR (the
# pak) — so nothing host-specific leaks into the engine; the engine binary is unchanged.
LODOR_CFG_DIR="${SHARED_USERDATA_PATH:-$SDCARD/.userdata/shared}/Lodor"
export LODOR_CFG_DIR

# lodor_migrate_cfg — one-time, idempotent, non-destructive move of any legacy in-pak config into
# LODOR_CFG_DIR. Only moves a file present in the pak AND absent in the shared dir; never overwrites
# a shared-dir file. Safe to call on every invocation.
lodor_migrate_cfg() {
	mkdir -p "$LODOR_CFG_DIR" 2>/dev/null || return 0
	for _cf in config.json settings.conf active-profile.txt; do
		if [ -f "$ROMM_PAK_DIR/$_cf" ] && [ ! -f "$LODOR_CFG_DIR/$_cf" ]; then
			mv -f "$ROMM_PAK_DIR/$_cf" "$LODOR_CFG_DIR/$_cf" 2>/dev/null || \
				cp -f "$ROMM_PAK_DIR/$_cf" "$LODOR_CFG_DIR/$_cf" 2>/dev/null
		fi
	done
	return 0
}

# --- TLS trust store (the static CGO-free engine has NO embedded CA bundle) ---
# Point the engine at the bundled Mozilla CA store via SSL_CERT_FILE (Go honors it). Graceful
# fallback to the device system store if the bundled certs dir was stripped.
if [ -f "$ROMM_PAK_DIR/certs/ca-certificates.crt" ]; then
	export SSL_CERT_FILE="$ROMM_PAK_DIR/certs/ca-certificates.crt"
elif [ -f /etc/ssl/certs/ca-certificates.crt ]; then
	export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
fi

# --- derive RomM host[:port] from config (probes only; the engine reads config itself) -------------
# Robust: any parse failure leaves ROMM_HOST unset and the advisory probes are simply skipped.
_parse_romm_uri() {
	[ -f "$LODOR_CFG_DIR/config.json" ] || return 1
	_u=$(sed -n 's/.*"root_uri"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LODOR_CFG_DIR/config.json" | head -1)
	[ -n "$_u" ] || return 1
	case "$_u" in https://*) _sch=https; _u=${_u#https://} ;; http://*) _sch=http; _u=${_u#http://} ;; *) _sch=https ;; esac
	_u=${_u%%/*}
	case "$_u" in
		*:*) _RH=${_u%%:*}; _RP=${_u##*:} ;;
		*)   _RH=$_u; if [ "$_sch" = http ]; then _RP=80; else _RP=443; fi ;;
	esac
	[ -n "$_RH" ] || return 1
	ROMM_HOST="${ROMM_HOST:-$_RH}"; ROMM_PORT="${ROMM_PORT:-$_RP}"
}
_parse_romm_uri 2>/dev/null
ROMM_PORT="${ROMM_PORT:-443}"
DATETIME_PATH="${DATETIME_PATH:-$SDCARD/.userdata/shared/datetime.txt}"
NET_TIMEOUT="${NET_TIMEOUT:-30}"
WIFI_LOG="${WIFI_LOG:-/dev/null}"
_WIFI_DBG="${WIFI_DBG:-$ROMM_PAK_DIR/wifi-debug.log}"
_wlog() { echo "$(date +'%F %T') pid=$$ $1" >> "$_WIFI_DBG" 2>/dev/null; }

# --- honest status line ------------------------------------------------------
# NextUI has no guaranteed text presenter for Tool paks, so this is primarily a log/parity sink
# (/tmp/romm-phase). Callers write a line ONLY when it is true at the moment written; failures
# replace the in-progress line with a specific honest reason.
_pset() { echo "$1" > /tmp/romm-phase 2>/dev/null; _wlog "phase: $1"; return 0; }

# --- link inspection (read-only; never changes radio state) ------------------
_have_up() { [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ]; }
_have_ip() { ip addr show wlan0 2>/dev/null | grep -q "inet "; }
_wlan_ip() { ip addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1; }
# "radio ready" = a USABLE link: operstate up + a real IPv4 lease. RomM reachability is a separate,
# downstream concern (engine exit code 3) and never gates this.
_radio_ready() { _have_up && _have_ip; }

# _radio_wait [secs] — poll _radio_ready for up to <secs> (default 8), 1s cadence, so a menu action
# opened during the boot-time Wi-Fi association race waits briefly for the link instead of flat-failing.
# Returns 0 as soon as the link is usable, else 1. NEVER a radio-power action (NextUI owns Wi-Fi) — only
# a read-only poll of an already-enabling interface. Honest by construction: it reports the REAL link
# state and never fabricates connectivity.
_radio_wait() {
	_rw_max="${1:-8}"; _rw_n=0
	while [ "$_rw_n" -lt "$_rw_max" ]; do
		_radio_ready && return 0
		sleep 1; _rw_n=$((_rw_n + 1))
	done
	_radio_ready
}

# --- DNS resolver guarantee (the pure-Go engine needs /etc/resolv.conf) ------
# The CGO-free engine uses Go's pure resolver, which requires a `nameserver` line in
# /etc/resolv.conf. NON-DESTRUCTIVE: if one already exists (NextUI/DHCP-provided), leave it. Else
# seed the default gateway (LAN-aware) + public fallbacks. Symlink fallback for a read-only /etc.
_ensure_resolv() {
	if grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
		_wlog "ensure_resolv: ok (existing)"; return 0
	fi
	_gw=$(ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
	_content=""
	[ -n "$_gw" ] && _content="nameserver $_gw"
	_content="${_content:+$_content
}nameserver 1.1.1.1
nameserver 8.8.8.8"
	if printf '%s\n' "$_content" > /etc/resolv.conf 2>/dev/null && grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
		_wlog "ensure_resolv: wrote /etc/resolv.conf (gw=${_gw:-none})"; return 0
	fi
	printf '%s\n' "$_content" > /tmp/resolv.conf 2>/dev/null
	if ln -sf /tmp/resolv.conf /etc/resolv.conf 2>/dev/null && grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
		_wlog "ensure_resolv: /etc/resolv.conf -> /tmp/resolv.conf symlink (gw=${_gw:-none})"; return 0
	fi
	_wlog "ensure_resolv: /etc/resolv.conf NOT writable (rootfs ro) — wanted gw=${_gw:-none}"
	return 1
}

# --- reachability — DIAGNOSTIC ONLY; never touches the radio (NextUI owns it) -
# We never re-enumerate / re-associate / power-cycle Wi-Fi on NextUI. Guarantee the resolver exists,
# probe RomM once for the log, then ALWAYS return 0 so the engine runs and surfaces its own honest
# exit code (3 = unreachable).
# HONESTY (task #134): on a tier-1 (socks5_proxy) config the engine dials THROUGH tailscaled —
# a kernel-path nc probe cannot see that transport (a MagicDNS host doesn't even resolve outside
# the tunnel), so the log line reports the TUNNEL state instead and never fakes a kernel verdict.
# Callers must run lodor_tier1_up BEFORE this so the tunnel-state read is post-bring-up.
wifi_ensure_reachable() {
	_ensure_resolv
	if command -v tailscale_is_tier1 >/dev/null 2>&1 && tailscale_is_tier1; then
		if [ "$(tailscale_status 2>/dev/null)" = "connected" ]; then
			_wlog "reach: ok (tier-1 tunnel Running, socks5 ${TS_SOCKS5_ADDR:-?} — engine transport verified)"
		else
			_wlog "reach: tier-1 tunnel NOT Running — engine socks5 dial will fail (see tailscaled.log; kernel-path probe skipped, it can't see this transport)"
		fi
		return 0
	fi
	if [ -n "${ROMM_HOST:-}" ] && command -v nc >/dev/null 2>&1; then
		if nc -z -w 4 "$ROMM_HOST" "${ROMM_PORT:-443}" >/dev/null 2>&1; then
			_wlog "reach: ok (RomM $ROMM_HOST:${ROMM_PORT:-443} reachable)"
		else
			_wlog "reach: nc probe to RomM $ROMM_HOST:${ROMM_PORT:-443} failed — ADVISORY ONLY (busybox nc is a known false-negative on this device; the pure-Go engine's happy-eyeballs connect is authoritative, not this probe)"
		fi
	elif [ -n "${ROMM_HOST:-}" ]; then
		_wlog "reach: probe skipped (no nc) — engine connect is authoritative"
	else
		_wlog "reach: probe skipped (host unparsed from config.json) — engine connect is authoritative"
	fi
	return 0
}

# --- coordination mutex (NO radio power — serializes transfers only) ---------
# Keeps the launch hooks, the daemon, and the Tool from running two transfers at once. fg preempts a
# preemptible (push) holder so a game launch never waits on a background save upload; bg never preempts.
_WIFI_LOCK="/tmp/romm-wifi.lock"
_WIFI_STALE=180   # a held lock older than this (s) with a dead/absent owner is reclaimable

# wifi_acquire [mode]   mode: fg = foreground (download / pre-game): preempts a preemptible holder.
#   push = post-game save upload: preemptible by fg.  bg = daemon (default): neither preempts nor is.
# returns: 0 = link up & usable, mutex held (caller MUST wifi_release); 2 = busy; 1 = Wi-Fi not connected.
#
# NextUI model: take the mutex, then RIDE the existing connection. We NEVER bring Wi-Fi up — if it is
# not already connected we fail honestly and tell the user to enable it in NextUI Settings.
wifi_acquire() {
	_acq_mode="${1:-bg}"
	while :; do
		if mkdir "$_WIFI_LOCK" 2>/dev/null; then
			echo "$$" > "$_WIFI_LOCK/owner"; date +%s > "$_WIFI_LOCK/ts"
			if [ "$_acq_mode" = push ]; then echo 1 > "$_WIFI_LOCK/preempt"; else rm -f "$_WIFI_LOCK/preempt" 2>/dev/null; fi
			[ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] && break
			continue
		fi
		owner=$(cat "$_WIFI_LOCK/owner" 2>/dev/null)
		ts=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); now=$(date +%s)
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null || [ $((now - ts)) -gt "$_WIFI_STALE" ]; then
			rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
			rmdir "$_WIFI_LOCK" 2>/dev/null
			continue
		fi
		if [ "$_acq_mode" = fg ] && [ "$(cat "$_WIFI_LOCK/preempt" 2>/dev/null)" = 1 ]; then
			_wlog "PREEMPT push owner=$owner (fg incoming)"
			kill -TERM "-$owner" 2>/dev/null || kill -TERM "$owner" 2>/dev/null
			j=0; while kill -0 "$owner" 2>/dev/null && [ "$j" -lt 30 ]; do sleep 0.1; j=$((j + 1)); done
			continue
		fi
		_wlog "acquire BUSY owner=$owner mode=$_acq_mode"
		return 2
	done

	# RIDE the existing NextUI Wi-Fi connection. Never bring the radio up.
	if _radio_ready; then
		_ensure_resolv
		_ip=$(_wlan_ip); [ -n "$_ip" ] && _pset "Online ($_ip)" || _pset "Online"
		_wlog "acquire OK (riding existing Wi-Fi link${_ip:+ $_ip})"
		return 0
	fi
	_pset "Wi-Fi not connected — enable it in NextUI settings"
	_wlog "acquire FAIL: wlan0 not up / no IP (NextUI owns Wi-Fi; not bringing it up)"
	wifi_release
	return 1
}

# wifi_release — drop the mutex ONLY. NEVER powers the radio down (NextUI owns it). Owner-scoped, so a
# trap/racer never disturbs another actor's transfer.
wifi_release() {
	if [ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ]; then
		_wlog "release (lock dropped; Wi-Fi LEFT UP — NextUI owns it)"
		rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
		rmdir "$_WIFI_LOCK" 2>/dev/null
	fi
	return 0
}

# --- clock (TLS needs a sane clock) ------------------------------------------
# Fast-path: if the clock already reads a sane recent year it has been set this session — skip
# instantly. NTP over UDP first (numeric IP, no DNS/TLS dependency); HTTP-Date last resort.
_persist_clock() { [ -n "$DATETIME_PATH" ] && date +'%F %T' > "$DATETIME_PATH" 2>/dev/null; return 0; }
set_clock() {
	_yr=$(date +%Y 2>/dev/null)
	if [ -n "$_yr" ] && [ "$_yr" -ge 2024 ] 2>/dev/null; then return 0; fi
	if command -v ntpd >/dev/null 2>&1 && ntpd -q -n -p 162.159.200.123 >/dev/null 2>&1; then _persist_clock; return 0; fi
	if command -v sntp >/dev/null 2>&1 && sntp -sS 162.159.200.123 >/dev/null 2>&1; then _persist_clock; return 0; fi
	if [ -n "${ROMM_HOST:-}" ]; then
		d="$(wget -T 8 -S -q -O /dev/null "http://$ROMM_HOST/" 2>&1 | sed -n 's/^ *Date: //p' | head -1)"
		if [ -n "$d" ] && date -s "$d" >/dev/null 2>&1; then _persist_clock; return 0; fi
	fi
	return 1
}

# --- gates -------------------------------------------------------------------
# Charging: NextUI/TrimUI exposes the standard Linux power_supply sysfs. If a status node reads
# Charging/Full -> charging. If NO status node is readable, we can't tell — and since NextUI owns
# Wi-Fi (no radio cost to us), treat "unknown" as charging so the light daemon cycle still runs.
is_charging() {
	_seen=0
	for _s in /sys/class/power_supply/*/status; do
		[ -r "$_s" ] || continue
		_seen=1
		case "$(cat "$_s" 2>/dev/null)" in Charging|Full) return 0 ;; esac
	done
	[ "$_seen" = 0 ]
}

# creds_present — NextUI manages its own Wi-Fi (no wifi.txt), so we only require a paired RomM config.
creds_present() {
	lodor_migrate_cfg
	[ -f "$LODOR_CFG_DIR/config.json" ] || return 1
	grep -q '"token"' "$LODOR_CFG_DIR/config.json" 2>/dev/null
}

# --- tier-1 (Tailscale) overlay ---------------------------------------------
# Load the Tailscale tier-1 helpers (defines tailscale_up / _is_tier1 / _status / _reset).
# Sourced AFTER LODOR_CFG_DIR / ROMM_PAK_DIR / SDCARD / PLAT are set (it keys off them).
if [ -f "$ROMM_PAK_DIR/lib/tailscale-lib.sh" ]; then
	. "$ROMM_PAK_DIR/lib/tailscale-lib.sh" 2>/dev/null || true
fi

# lodor_tier1_up -- bring the userspace tailnet up (reusing the QR-onboarded login) ONLY
# when config.json is a tier-1 host (carries socks5_proxy). Idempotent + non-fatal: a
# LAN / public-URL config is a no-op, and a failed bring-up just lets the engine surface
# its own unreachable (rc 3). The daemon is left resident for the session (reused, not
# re-spun every call); "Turn off" / "Reset & forget" in the menu tear it down.
lodor_tier1_up() {
	command -v tailscale_is_tier1 >/dev/null 2>&1 || return 0
	tailscale_is_tier1 || return 0
	# Honest one-liner either way (task #134): the wifi-debug log says whether the engine's
	# SOCKS5 transport is actually up, or where to read why it isn't.
	if tailscale_up >/dev/null 2>&1; then
		_wlog "tier1: tunnel up (engine can socks5h-dial ${TS_SOCKS5_ADDR:-the proxy})"
	else
		_wlog "tier1: bring-up FAILED — engine dial will surface rc 3 (why: tailscaled.log)"
	fi
	return 0
}

# --- run the sync binary -----------------------------------------------------
# Runs from the pak dir so the engine reads config.json (CWD-relative). The clean engine reads ONLY
# BASE_PATH / SDCARD_PATH / PLATFORM for path resolution (no CFW / IS_MIYOO — those are dead in the
# rewrite). A bare run_sync expands to the light background flush (push pending saves); a run_sync
# WITH args passes through unchanged. Returns the engine exit code (0 ok / 2 cfg / 3 unreachable /
# 4 ran-but-errored).
run_sync() {
	_ensure_resolv
	lodor_migrate_cfg
	# tier-1 BEFORE the reach log (task #134): the probe reports the tunnel state on tier-1
	# configs, so bring it up (or reuse it) first; migrate first so is_tier1 reads the real config.
	lodor_tier1_up
	wifi_ensure_reachable || true
	# CWD = LODOR_CFG_DIR so the engine loads config.json / settings.conf / active-profile.txt from
	# NextUI's shared userdata; LODOR_PAK_DIR (already exported) keeps engine STATE in the pak.
	( cd "$LODOR_CFG_DIR" || exit 2
	  export BASE_PATH="$SDCARD"
	  export SDCARD_PATH="$SDCARD"
	  export PLATFORM="$PLAT"
	  if [ "$#" -gt 0 ]; then
	  	"$SYNC_BIN" "$@"; exit $?
	  fi
	  # Bare "full sync" -> light pending-save flush only. The heavy catalog/collections mirror is a
	  # user-driven Tool action (launch.sh), not something the daemon re-runs every cycle. (No --recent:
	  # the clean engine has no such flag and the index-0 Continue tile is a LodorOS-only integration.)
	  "$SYNC_BIN" --push-pending; exit $?
	)
}
