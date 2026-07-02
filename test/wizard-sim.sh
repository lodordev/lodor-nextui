#!/bin/bash
# wizard-sim.sh — off-device (x86) simulator for the NextUI Lodor.pak wizard + menu shell flows.
#
# Runs the REAL launch.sh + lib/*.sh headlessly inside a throwaway fake-SD-card sandbox:
#   sandbox/sdcard/Tools/tg5040/Lodor.pak/    <- real launch.sh + lib + hooks, STUB binaries at the
#                                                exact $PAKDIR-relative paths the script resolves
#                                                (bin/tg5040/minui-*, bin/tg5040/lodor-qr, lodor-sync,
#                                                bin/romm-run, bin/romm-syncd, bin/tailscale/*)
#   PATH-shadowed:  sleep (time compression), killall (no-op), simq (queue pop)
#   LODOR_TEST_LIB: testlib.sh overrides the wlan0/tailscale/host-state helpers (see that file)
#
# Every stub reads its scripted behavior from per-channel queues built from a .scn scenario file
# (sticky-last-line FIFO — see stubs/simq). The run is wrapped in `timeout`: an interaction loop
# that stops consuming script and spins (the class of bug that shipped in the network-choice
# wizard step) fails the scenario as TIMEOUT instead of hanging CI.
#
# Usage: wizard-sim.sh <scenario.scn> [--keep]
# Exit:  0 scenario passed, 1 failed (reasons on stdout), 2 harness/usage error.
#
# Scenario directives (one per line; '#' comments):
#   desc <text>                        human description
#   timeout <secs>                     real-time budget (default 30)
#   args <argv>                        argv for launch.sh (e.g. --game-manager)
#   invoke launch|emupak|prehook|posthook|boothook|tslib|ctpak
#                                      what to run (default launch = Tools pak launch.sh).
#                                      emupak   = Emus/tg5040/LODORGM.pak/launch.sh '<SD>/<romarg>'
#                                      prehook  = hooks/pre-launch.d/10-lodor-fetch.sync.sh (HOOK_* env)
#                                      posthook = hooks/post-launch.d/90-lodor-pushsave.sh  (HOOK_* env)
#                                      boothook = hooks/boot.d/10-lodor.sh (SDCARD_PATH/PLATFORM env,
#                                                 like MinUI.pak's boot.d pass — GM assets NOT
#                                                 pre-staged: the boot heal is what's under test)
#                                      ctpak    = Emus/tg5040/LODORCT.pak/launch.sh '<SD>/<romarg>'
#                                                 (the resume dispatcher; stages CT card assets +
#                                                 a RECORDER GBA emu pak that traces EMULAUNCH)
#                                      emupak/prehook/posthook pre-stage the SHIPPED GM card assets
#                                      (Emus pak + Roms root-entry folder), assemble.sh parity
#   romarg <sd-relative-path>          the ROM path for emupak/prehook/posthook (default = GM dummy entry)
#   wifi up|down                       scripted wlan0 state
#   ts present|absent                  bundle bin/tailscale/{tailscaled,tailscale} dummies or not
#   tsdaemon die|never|slow:<ticks>    bundle the SCRIPTED fake tailscaled/tailscale (invoke tslib:
#                                      exercises the REAL tailscale-lib wait/reuse logic)
#   tsdrv <step>                       queue a ts-driver.sh step (wait=<s>|up|alive|count|down)
#   no-kb | no-list                    omit the minui-keyboard / minui-list stub (missing-binary path)
#   config none|server|paired          initial config.json state in the shared userdata dir
#   seeded                             pre-create the pak's .library-seeded sentinel
#   sdfile <sd-relative-path>          create a 0-byte file (a Lodor stub) on the fake card
#   sdfile+ <sd-relative-path>         create a real (non-empty) file on the fake card
#   sdtext <rel-path>TAB<content>      create a card file with scripted content (%b-expanded)
#   settings <key>=<value>            append a line to settings.conf
#   pick <rc>|<text>                   queue a minui-list answer      (channel: list)
#   kb <rc>|<text>                     queue a minui-keyboard answer  (channel: kb)
#   qr <mode>                          queue a lodor-qr behavior      (0 faithful/2/3/4/139)
#   engine <rc>|<stdout>               queue an engine result (%b-expanded: \t \n allowed)
#   tsurl <url|(empty)>                queue a tailscale_up_interactive login URL
#   tsstatus connected|pending|stopped queue a tailscale_status answer
#   expect_exit <n>                    launch.sh must exit n (124 = harness timeout)
#   expect_config_has <substr>         config.json contains substring
#   expect_config_lacks <substr>       config.json missing OR lacks substring
#   expect_config_absent               no config.json written
#   expect_trace <substr>              trace.log contains substring
#   expect_trace_absent <substr>       trace.log lacks substring
#   expect_log <substr>                pak last-sync.log contains substring
#   expect_file <sd-relative-path>     file exists under the fake SD card
#   expect_file_absent <sd-relative-path>  file does NOT exist under the fake SD card
#   expect_file_empty <sd-relative-path>   file exists AND is 0 bytes (an intact Lodor stub)
#   expect_file_has <rel-path> <substr>    (TAB-separate the two when the path has spaces)
#   expect_file_lines <rel-path> <n>       file has exactly n non-blank lines (TAB-separate
#                                          when the path has spaces) — dedup/count assertions
set -u

SCN="${1:-}"
KEEP="${2:-}"
[ -f "$SCN" ] || { echo "usage: wizard-sim.sh <scenario.scn> [--keep]" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PAKSRC="${LODOR_PAK_SRC:-$HERE/../Lodor.pak}"
[ -f "$PAKSRC/launch.sh" ] || { echo "FATAL: pak source not found at $PAKSRC" >&2; exit 2; }

NAME="$(basename "$SCN" .scn)"
ROOT="$(mktemp -d "/tmp/lodor-wizsim.$NAME.XXXXXX")"
SD="$ROOT/sdcard"
PAK="$SD/Tools/tg5040/Lodor.pak"
SIM="$ROOT/sim"
BIN="$ROOT/bin"
CFGDIR="$SD/.userdata/shared/Lodor"
mkdir -p "$PAK/bin/tg5040" "$SIM/q" "$BIN" "$CFGDIR"

# ---- lay down the REAL pak scripts ----
cp "$PAKSRC/launch.sh" "$PAK/launch.sh"
cp -r "$PAKSRC/lib" "$PAK/lib"
cp -r "$PAKSRC/hooks" "$PAK/hooks"
[ -d "$PAKSRC/gmpak" ] && cp -r "$PAKSRC/gmpak" "$PAK/gmpak"   # Game Manager root-entry sources
[ -d "$PAKSRC/ctpak" ] && cp -r "$PAKSRC/ctpak" "$PAK/ctpak"   # Continue root-entry sources

# ---- stubs at the exact paths launch.sh resolves ----
for s in minui-list minui-keyboard minui-presenter lodor-qr; do
	cp "$HERE/stubs/$s" "$PAK/bin/tg5040/$s"
done
cp "$HERE/stubs/lodor-sync"  "$PAK/lodor-sync"
mkdir -p "$PAK/bin"
cp "$HERE/stubs/romm-run"    "$PAK/bin/romm-run"
cp "$HERE/stubs/romm-syncd"  "$PAK/bin/romm-syncd"
for s in simq sleep killall show2.elf; do cp "$HERE/stubs/$s" "$BIN/$s"; done
chmod +x "$PAK"/bin/tg5040/* "$PAK/lodor-sync" "$PAK"/bin/romm-* "$BIN"/*

# ---- defaults ----
TMO=30
DESC=""
INVOKE="launch"       # what to run: launch (Tools pak) | emupak (root-entry Emus pak) | prehook | posthook
LAUNCH_ARGS=""        # argv for launch.sh (e.g. --game-manager)
ROMARG=""             # sd-relative ROM path handed to emupak/prehook/posthook
echo up > "$SIM/wifi"
EXPECTS="$ROOT/expects"
: > "$EXPECTS"

# stage_gm_card — lay the SHIPPED Game Manager card assets (Emus pak + Roms root-entry folder)
# into the fake SD, exactly as assemble.sh stages them. Used by the non-launch invokes; `invoke
# launch` scenarios exercise the SELF-INSTALL path instead (assets absent until launch.sh heals).
stage_gm_card() {
	[ -d "$PAKSRC/gmpak" ] || return 0
	mkdir -p "$SD/Emus/tg5040/LODORGM.pak"
	cp "$PAKSRC/gmpak/launch.sh" "$SD/Emus/tg5040/LODORGM.pak/launch.sh"
	chmod +x "$SD/Emus/tg5040/LODORGM.pak/launch.sh"
	mkdir -p "$SD/Roms/Game Manager (LODORGM)"
	# data files are NO-CLOBBER: a scenario may pre-shape them (e.g. a truncated dummy entry)
	[ -e "$SD/Roms/Game Manager (LODORGM)/Open Game Manager.gm" ] || \
		cp "$PAKSRC/gmpak/roms/Open Game Manager.gm" "$SD/Roms/Game Manager (LODORGM)/Open Game Manager.gm"
	[ -e "$SD/Roms/Game Manager (LODORGM)/Game Manager (LODORGM).m3u" ] || \
		cp "$PAKSRC/gmpak/roms/Game Manager (LODORGM).m3u" "$SD/Roms/Game Manager (LODORGM)/Game Manager (LODORGM).m3u"
}

# stage_ct_card — lay the SHIPPED Continue root-entry card assets (LODORCT dispatcher Emus
# pak + Roms dummy folder) plus a RECORDER GBA emulator pak that traces its argv — so ctpak
# scenarios can assert the dispatcher launched the REAL game (EMULAUNCH rom='<path>').
stage_ct_card() {
	[ -d "$PAKSRC/ctpak" ] || return 0
	mkdir -p "$SD/Emus/tg5040/LODORCT.pak"
	cp "$PAKSRC/ctpak/launch.sh" "$SD/Emus/tg5040/LODORCT.pak/launch.sh"
	chmod +x "$SD/Emus/tg5040/LODORCT.pak/launch.sh"
	mkdir -p "$SD/Roms/0) Continue (LODORCT)"
	[ -e "$SD/Roms/0) Continue (LODORCT)/Continue.ct" ] || \
		cp "$PAKSRC/ctpak/roms/Continue.ct" "$SD/Roms/0) Continue (LODORCT)/Continue.ct"
	[ -e "$SD/Roms/0) Continue (LODORCT)/0) Continue (LODORCT).m3u" ] || \
		cp "$PAKSRC/ctpak/roms/0) Continue (LODORCT).m3u" "$SD/Roms/0) Continue (LODORCT)/0) Continue (LODORCT).m3u"
	mkdir -p "$SD/Emus/tg5040/GBA.pak"
	cat > "$SD/Emus/tg5040/GBA.pak/launch.sh" <<'REC'
#!/bin/sh
echo "EMULAUNCH rom='$1'" >> "${LODOR_SIM_DIR:?}/trace.log"
exit 0
REC
	chmod +x "$SD/Emus/tg5040/GBA.pak/launch.sh"
}

seed_config() {
	case "$1" in
		none) rm -f "$CFGDIR/config.json" ;;
		server)
			cat > "$CFGDIR/config.json" <<'EOF'
{
  "hosts": [
    {
      "root_uri": "https://seed.example.com",
      "stub": true
    }
  ]
}
EOF
			;;
		paired)
			cat > "$CFGDIR/config.json" <<'EOF'
{
  "hosts": [
    {
      "root_uri": "https://seed.example.com",
      "device_name": "stub-device",
      "token": "stub-token",
      "stub": true
    }
  ]
}
EOF
			;;
		tier1)
			# tier-1 (Tailscale) host: socks5_proxy + tier mark the engine's SOCKS5 transport
			# (what tailscale_mark_tier1 writes). Drives lodor_tier1_up / the honest reach probe.
			cat > "$CFGDIR/config.json" <<'EOF'
{
  "hosts": [
    {
      "root_uri": "http://seed-romm.example-tailnet.ts.net",
      "socks5_proxy": "localhost:1055",
      "tier": 1,
      "device_name": "stub-device",
      "token": "stub-token",
      "stub": true
    }
  ]
}
EOF
			;;
		*) echo "FATAL: unknown config seed '$1'" >&2; exit 2 ;;
	esac
}

# ---- parse the scenario ----
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
	lineno=$((lineno + 1))
	line="${raw%%$'\r'}"
	case "$line" in ''|'#'*) continue ;; esac
	cmd="${line%% *}"
	arg="${line#* }"; [ "$arg" = "$line" ] && arg=""
	case "$cmd" in
		desc)      DESC="$arg" ;;
		timeout)   TMO="$arg" ;;
		args)      LAUNCH_ARGS="$arg" ;;
		invoke)
			case "$arg" in
				launch|emupak|prehook|posthook|boothook|tslib|ctpak) INVOKE="$arg" ;;
				*) echo "FATAL: $SCN:$lineno unknown invoke '$arg'" >&2; exit 2 ;;
			esac ;;
		romarg)    ROMARG="$arg" ;;
		wifi)      echo "$arg" > "$SIM/wifi" ;;
		ts)
			if [ "$arg" = present ]; then
				mkdir -p "$PAK/bin/tailscale"
				printf '#!/bin/sh\nexit 0\n' > "$PAK/bin/tailscale/tailscaled"
				printf '#!/bin/sh\nexit 0\n' > "$PAK/bin/tailscale/tailscale"
				chmod +x "$PAK/bin/tailscale/tailscaled" "$PAK/bin/tailscale/tailscale"
			fi ;;
		tsdaemon)
			mkdir -p "$PAK/bin/tailscale"
			cp "$HERE/stubs/tailscaled" "$PAK/bin/tailscale/tailscaled"
			cp "$HERE/stubs/tailscale"  "$PAK/bin/tailscale/tailscale"
			chmod +x "$PAK/bin/tailscale/tailscaled" "$PAK/bin/tailscale/tailscale"
			printf '%s\n' "$arg" > "$SIM/tsdaemon.mode" ;;
		tsdrv)     printf '%s\n' "$arg" >> "$SIM/tssteps" ;;
		no-kb)     rm -f "$PAK/bin/tg5040/minui-keyboard" ;;
		no-list)   rm -f "$PAK/bin/tg5040/minui-list" ;;
		config)    seed_config "$arg" ;;
		seeded)    : > "$PAK/.library-seeded" ;;
		sdfile)    mkdir -p "$SD/$(dirname "$arg")"; : > "$SD/$arg" ;;                       # 0-byte stub
		sdfile+)   mkdir -p "$SD/$(dirname "$arg")"; printf 'REALBYTES\n' > "$SD/$arg" ;;    # real (downloaded) file
		sdtext)    # content-controlled card file: <rel-path>TAB<content>, %b-expanded (\t \n)
			_st="$(printf '\t')"
			_sp="${arg%%"$_st"*}"; _sc="${arg#*"$_st"}"
			mkdir -p "$SD/$(dirname "$_sp")"; printf '%b' "$_sc" > "$SD/$_sp" ;;
		settings)  echo "$arg" >> "$CFGDIR/settings.conf" ;;
		pick)      printf '%s\n' "$arg" >> "$SIM/q/list.q" ;;
		kb)        printf '%s\n' "$arg" >> "$SIM/q/kb.q" ;;
		qr)        printf '%s\n' "$arg" >> "$SIM/q/qr.q" ;;
		engine)    printf '%s\n' "$arg" >> "$SIM/q/engine.q" ;;
		tsurl)     printf '%s\n' "$arg" >> "$SIM/q/tsurl.q" ;;
		tsstatus)  printf '%s\n' "$arg" >> "$SIM/q/tsstatus.q" ;;
		expect_*)  printf '%s\n' "$line" >> "$EXPECTS" ;;
		*) echo "FATAL: $SCN:$lineno unknown directive '$cmd'" >&2; exit 2 ;;
	esac
done < "$SCN"

# ---- clean device-global /tmp state the pak scripts touch (device-faithful defaults) ----
rm -rf /tmp/lodor-ts-state /tmp/lodor-qr-state /tmp/lodor-tailscaled.sock \
       /tmp/lodor-menu-out /tmp/lodor-menu-list /tmp/lodor-setup-kb /tmp/lodor-setup-pick \
       /tmp/lodor-setup-pick-list /tmp/lodor-feed-list /tmp/lodor-feed-out /tmp/lodor-feed.txt \
       /tmp/lodor-user-list /tmp/lodor-user-ids /tmp/lodor-user-out /tmp/lodor-gm-ids \
       /tmp/romm-wifi.lock /tmp/romm-phase /tmp/show2.fifo /tmp/dl-progress 2>/dev/null

# ---- run ----
export LODOR_SIM_DIR="$SIM"
export LODOR_TEST_LIB="$HERE/testlib.sh"
export SDCARD_PATH="$SD"
export SHARED_USERDATA_PATH="$SD/.userdata/shared"
export PLATFORM="tg5040"
export PATH="$BIN:$PATH"

# Non-launch invokes run against the SHIPPED card layout (assemble.sh parity), not self-install.
case "$INVOKE" in emupak|prehook|posthook) stage_gm_card ;; esac
case "$INVOKE" in ctpak|prehook|posthook) stage_ct_card ;; esac

case "$INVOKE" in
	launch)
		# shellcheck disable=SC2086  # LAUNCH_ARGS is intentionally word-split (argv)
		( timeout -k 5 "$TMO" sh "$PAK/launch.sh" $LAUNCH_ARGS > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	emupak)
		# NextUI's launch contract: '<emu pak launch.sh>' '<rom path>' with SDCARD_PATH/PLATFORM in env.
		: "${ROMARG:=Roms/Game Manager (LODORGM)/Open Game Manager.gm}"
		( timeout -k 5 "$TMO" sh "$SD/Emus/tg5040/LODORGM.pak/launch.sh" "$SD/$ROMARG" \
			> "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	boothook)
		# MinUI.pak's boot.d contract: SDCARD_PATH/PLATFORM in env, run to completion before the
		# first nextui.elf — the window the GM root-entry boot heal (task #131) relies on.
		( timeout -k 5 "$TMO" sh "$PAK/hooks/boot.d/10-lodor.sh" > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	ctpak)
		# NextUI's launch contract for the Continue root row: dispatcher + dummy entry path.
		: "${ROMARG:=Roms/0) Continue (LODORCT)/Continue.ct}"
		( timeout -k 5 "$TMO" env LODOR_CFG_DIR="$CFGDIR" \
			sh "$SD/Emus/tg5040/LODORCT.pak/launch.sh" "$SD/$ROMARG" \
			> "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	tslib)
		# REAL tailscale-lib under test (STEP 0a): sandbox-scoped socket/state paths, scripted
		# fake daemon (tsdaemon), steps from $SIM/tssteps. See ts-driver.sh.
		cp "$HERE/ts-driver.sh" "$ROOT/ts-driver.sh"
		( timeout -k 5 "$TMO" env TS_SOCK="$ROOT/ts.sock" TS_STATEDIR="$ROOT/ts-state" \
			LODOR_CFG_DIR="$CFGDIR" sh "$ROOT/ts-driver.sh" > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	prehook|posthook)
		# NextUI's run_hooks.sh contract: HOOK_* in env, script run to completion, output suppressed.
		: "${ROMARG:=Roms/Game Manager (LODORGM)/Open Game Manager.gm}"
		_hs="$PAK/hooks/pre-launch.d/10-lodor-fetch.sync.sh"
		_hp="pre"
		if [ "$INVOKE" = posthook ]; then _hs="$PAK/hooks/post-launch.d/90-lodor-pushsave.sh"; _hp="post"; fi
		( timeout -k 5 "$TMO" env HOOK_PHASE="$_hp" HOOK_TYPE=rom HOOK_ROM_PATH="$SD/$ROMARG" \
			HOOK_EMU_PATH="$SD/Emus/tg5040/LODORGM.pak/launch.sh" HOOK_CMD="sim" HOOK_LAST="" \
			LODOR_CFG_DIR="$CFGDIR" \
			sh "$_hs" > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
esac
# reap any orphaned background subshells (status writers etc) from this sandbox
pkill -f "$ROOT" 2>/dev/null
/bin/sleep 0.1

# ---- evaluate expectations ----
fails=0
fail() { echo "  FAIL: $1"; fails=$((fails + 1)); }
CFG="$CFGDIR/config.json"
TRACE="$SIM/trace.log"
PAKLOG="$PAK/last-sync.log"

while IFS= read -r ex; do
	ecmd="${ex%% *}"
	earg="${ex#* }"; [ "$earg" = "$ex" ] && earg=""
	case "$ecmd" in
		expect_exit)
			if [ "$rc" != "$earg" ]; then
				if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
					fail "TIMEOUT after ${TMO}s (wanted exit $earg) — possible interaction loop"
				else
					fail "exit=$rc wanted=$earg"
				fi
			fi ;;
		expect_config_absent)
			[ -f "$CFG" ] && fail "config.json exists but should not" ;;
		expect_config_has)
			grep -qF "$earg" "$CFG" 2>/dev/null || fail "config.json lacks: $earg" ;;
		expect_config_lacks)
			grep -qF "$earg" "$CFG" 2>/dev/null && fail "config.json unexpectedly has: $earg" ;;
		expect_trace)
			grep -qF "$earg" "$TRACE" 2>/dev/null || fail "trace lacks: $earg" ;;
		expect_trace_absent)
			grep -qF "$earg" "$TRACE" 2>/dev/null && fail "trace unexpectedly has: $earg" ;;
		expect_log)
			grep -qF "$earg" "$PAKLOG" 2>/dev/null || fail "pak log lacks: $earg" ;;
		expect_file)
			[ -e "$SD/$earg" ] || fail "missing file: $earg" ;;
		expect_file_absent)
			[ -e "$SD/$earg" ] && fail "file exists but should not: $earg" ;;
		expect_file_empty)
			if [ ! -e "$SD/$earg" ]; then fail "missing file (stub deleted?): $earg"
			elif [ -s "$SD/$earg" ]; then fail "file has bytes but should be a 0-byte stub: $earg"
			fi ;;
		expect_file_has)
			# tab-separated when the path itself contains spaces; else first-space split
			tab="$(printf '\t')"
			case "$earg" in
				*"$tab"*) p="${earg%%"$tab"*}"; s="${earg#*"$tab"}" ;;
				*)        p="${earg%% *}"; s="${earg#* }" ;;
			esac
			grep -qF "$s" "$SD/$p" 2>/dev/null || fail "$p lacks: $s" ;;
		expect_file_lines)
			tab="$(printf '\t')"
			case "$earg" in
				*"$tab"*) p="${earg%%"$tab"*}"; n="${earg#*"$tab"}" ;;
				*)        p="${earg%% *}"; n="${earg#* }" ;;
			esac
			if [ -f "$SD/$p" ]; then got="$(grep -c . "$SD/$p" 2>/dev/null)"; else got=MISSING; fi
			[ "$got" = "$n" ] || fail "$p has $got non-blank line(s), wanted $n" ;;
		*) fail "harness: unknown expectation '$ecmd'" ;;
	esac
done < "$EXPECTS"

if [ "$fails" = 0 ]; then
	echo "PASS  $NAME${DESC:+  — $DESC}"
	[ "$KEEP" = "--keep" ] || rm -rf "$ROOT"
	exit 0
else
	echo "FAIL  $NAME${DESC:+  — $DESC}  (exit=$rc, artifacts: $ROOT)"
	exit 1
fi
