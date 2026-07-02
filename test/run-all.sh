#!/bin/bash
# run-all.sh — run every scenario in scenarios/ through wizard-sim.sh; PASS/FAIL per line,
# summary at the end, exit non-zero on any FAIL. Optional args: scenario names (sans .scn)
# to run a subset, e.g. `./run-all.sh w-ts-happy m-sync-now`.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 2

if [ $# -gt 0 ]; then
	set -- "${@/#/scenarios/}"
	set -- "${@/%/.scn}"
else
	set -- scenarios/*.scn
fi

pass=0; failn=0; failed=""
start=$(date +%s)
for scn in "$@"; do
	[ -f "$scn" ] || { echo "FAIL  $scn — scenario file not found"; failn=$((failn+1)); failed="$failed $(basename "$scn" .scn)"; continue; }
	if ./wizard-sim.sh "$scn"; then
		pass=$((pass+1))
	else
		failn=$((failn+1)); failed="$failed $(basename "$scn" .scn)"
	fi
done
dur=$(( $(date +%s) - start ))
echo "----------------------------------------------------------------------"
echo "wizard-sim: $pass passed, $failn failed (${dur}s)"
[ "$failn" = 0 ] || { echo "failed:$failed"; exit 1; }
exit 0
