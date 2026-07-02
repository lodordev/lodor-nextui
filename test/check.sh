#!/bin/bash
# check.sh — the one-command gate for the NextUI Lodor.pak shell surface:
#   1. STATIC:  bash -n + dash -n parse of every pak/hook/test script, then shellcheck
#               (local binary, else the koalaman/shellcheck docker image, else skipped
#               with a warning — parse checks still gate).
#   2. DYNAMIC: the full wizard-sim scenario matrix (run-all.sh).
# Exit non-zero on any failure. Intended wiring: call from assemble.sh (or the release
# path) BEFORE staging the pak — see the commented hook line in ../assemble.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
NEXTUI="$(cd "$HERE/.." && pwd)"
fails=0

# ---- the shell surface under gate ----
# POSIX_FILES run on-device under busybox ash (or in the sim under dash) — they MUST parse in a
# POSIX shell. BASH_FILES are the x86-only harness scripts (#!/bin/bash, arrays) — bash -n only.
POSIX_FILES=(
	"$NEXTUI/Lodor.pak/launch.sh"
	"$NEXTUI/Lodor.pak/lib/romm-sync-lib.sh"
	"$NEXTUI/Lodor.pak/lib/tailscale-lib.sh"
	"$NEXTUI/Lodor.pak/lib/show2-lib.sh"
	"$NEXTUI/Lodor.pak/bin/romm-run"
	"$NEXTUI/Lodor.pak/bin/romm-syncd"
	"$NEXTUI"/Lodor.pak/hooks/*/*.sh
	"$NEXTUI/Lodor.pak/gmpak/launch.sh"
	"$NEXTUI/Lodor.pak/ctpak/launch.sh"
	"$NEXTUI/assemble.sh"
	"$HERE/testlib.sh"
	"$HERE/ts-driver.sh"
	"$HERE"/stubs/*
)
BASH_FILES=(
	"$HERE/wizard-sim.sh"
	"$HERE/run-all.sh"
	"$HERE/check.sh"
	"$HERE/rootscan/run.sh"
)
FILES=("${POSIX_FILES[@]}" "${BASH_FILES[@]}")

echo "== static: bash -n + POSIX-sh parse =="
# POSIX parser: dash where present (dev container / debian), else busybox ash (Unraid/panther) —
# the on-device shell is busybox ash, so a POSIX-family parse matters more than which one.
POSIX_SH=()
if command -v dash >/dev/null 2>&1; then POSIX_SH=(dash)
elif command -v busybox >/dev/null 2>&1; then POSIX_SH=(busybox ash)
else echo "WARN: no dash/busybox — POSIX parse skipped (bash -n still gates)"
fi
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "GATE FAIL: missing $f"; fails=$((fails+1)); continue; }
	bash -n "$f" || { echo "GATE FAIL: bash -n $f"; fails=$((fails+1)); }
done
if [ "${#POSIX_SH[@]}" -gt 0 ]; then
	for f in "${POSIX_FILES[@]}"; do
		[ -f "$f" ] || continue
		"${POSIX_SH[@]}" -n "$f" || { echo "GATE FAIL: ${POSIX_SH[*]} -n $f"; fails=$((fails+1)); }
	done
fi

echo "== static: shellcheck =="
# Pinned excludes — each reviewed against a REAL finding 2026-07-02; do NOT grow without a reason:
#   SC1090/SC1091  sources resolved at runtime ($PAKDIR/lib/…, $LODOR_TEST_LIB) — not followable
#   SC2015         `[ -n $_ip ] && _pset A || _pset B` in romm-sync-lib — _pset always returns 0,
#                  so the B-after-A hazard cannot fire; the idiom is intentional there
#   SC2018/SC2019  `tr A-Z a-z` in tailscale-lib's _ts_hostname — ASCII is CORRECT for a DNS label
#   SC2034         cross-file vars: read-field placeholders (hdev) + vars consumed by a script the
#                  file sources or that sources it (WIFI_LOG, SHOW2_LOGO/…) — contract, not dead
#   SC2209         `TS_BG=nohup` — assigning a literal command NAME is the point
SC_EXCLUDES="SC1090,SC1091,SC2015,SC2018,SC2019,SC2034,SC2209"
run_shellcheck() {
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck -x -e "$SC_EXCLUDES" "$@"
	elif command -v docker >/dev/null 2>&1 && docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
		ROOT="$(cd "$NEXTUI/../.." && pwd)"   # repo root — all gated files live under it
		# PROBE the bind mount first: a docker CLI pointed at a REMOTE daemon (socket proxy)
		# would silently mount the remote host's paths instead of these files.
		printf '#!/bin/sh\n' > "$ROOT/.sc-probe.sh"
		if ! docker run --rm -v "$ROOT":/mnt koalaman/shellcheck:stable /mnt/.sc-probe.sh >/dev/null 2>&1; then
			rm -f "$ROOT/.sc-probe.sh"
			echo "WARN: docker daemon cannot see this filesystem (remote daemon?) — SKIPPING shellcheck"
			return 0
		fi
		rm -f "$ROOT/.sc-probe.sh"
		local rel=() f
		for f in "$@"; do rel+=("${f#"$ROOT"/}"); done
		docker run --rm -v "$ROOT":/mnt -w /mnt koalaman/shellcheck:stable \
			-x -e "$SC_EXCLUDES" "${rel[@]}"
	else
		echo "WARN: shellcheck not available (no binary, no docker image) — SKIPPING lint (parse checks still ran)"
		return 0
	fi
}
existing=()
for f in "${FILES[@]}"; do [ -f "$f" ] && existing+=("$f"); done
run_shellcheck "${existing[@]}" || { echo "GATE FAIL: shellcheck"; fails=$((fails+1)); }

echo "== dynamic: wizard-sim scenario matrix =="
"$HERE/run-all.sh" || fails=$((fails+1))

echo "== dynamic: engine merge/prune-safety fixture (synthetic user card, C2) =="
# The §8 beta-gate proof: a card of USER files survives mirror/refresh/download/
# evict/mode-flip/uninstall byte-identically (sha256), driven through the REAL
# engine against a fake RomM (engine/cmd/lodor-sync/merge_fixture_test.go). Runs
# with a local go toolchain; WARN-skips when none is available (the engine's own
# `go test ./...` gate still covers it wherever engines are built).
ENGINE_DIR="$(cd "$NEXTUI/../.." && pwd)/engine"
if command -v go >/dev/null 2>&1 && [ -d "$ENGINE_DIR" ]; then
	if (cd "$ENGINE_DIR" && go test ./cmd/lodor-sync/ ./catalog/ ./platform/ -run 'TestMergeFixture|TestMerge|TestPrune|TestManifest|TestReclaim|TestEvict|TestUninstall|TestMigrate|TestReconcileGuarded' -count=1 >/dev/null 2>&1); then
		echo "engine fixture: PASS"
	else
		echo "GATE FAIL: engine merge/prune-safety fixture"; fails=$((fails+1))
	fi
else
	echo "WARN: go toolchain not available — engine fixture skipped (covered by the engine build gate)"
fi

echo "== dynamic: NextUI root-scan harness (Game Manager root row, task #131) =="
# Compiles the REAL NextUI scan chain against our exact staged names; WARN-skips itself when the
# NextUI clone or docker is unavailable (see rootscan/run.sh).
"$HERE/rootscan/run.sh" || { echo "GATE FAIL: rootscan"; fails=$((fails+1)); }

echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "check.sh: ALL GATES PASSED"
	exit 0
fi
echo "check.sh: $fails gate(s) FAILED"
exit 1
