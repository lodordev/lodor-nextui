#!/bin/sh
export LODOR_HOST_OS=nextui
# Lodor push-save + marker reconcile (NextUI post-launch hook). Runs AFTER the game exits.
#   1. Pushes this ROM's save to RomM (verified upload, offline-staged) so device progress lands on the server.
#   2. Flips the on-disk state marker (✘ cloud -> ✓ on-device) for a game that was just downloaded,
#      now that it has exited and a rename is SAFE (a rename during the download->launch sequence
#      would pull the file out from under the launcher — the reason decision #69 reverted relocate).
#
# Env exported by NextUI's MinUI.pak launch.sh / run_hooks.sh:
#   HOOK_TYPE     = "rom" | "pak"
#   HOOK_ROM_PATH = absolute path to the ROM that just exited (when HOOK_TYPE=rom)
#   SDCARD_PATH, PLATFORM
[ "${HOOK_TYPE:-}" = "rom" ] || exit 0
[ -n "${HOOK_ROM_PATH:-}" ] || exit 0

# Game Manager / Continue ROOT ENTRIES (tasks #128/#134): the dummy entries under
# Roms/"Game Manager (LODORGM)"/ and Roms/"0) Continue (LODORCT)"/ are not games — no save to
# sync, no marker to reconcile (the Continue dispatcher runs this hook itself with the REAL
# game's path). Skip before any engine call. (The engine would refuse them anyway — neither
# tag maps to a platform, so --push-save/--reconcile resolve-fail — this guard just keeps the
# exit instant and log-quiet.)
case "$HOOK_ROM_PATH" in *"(LODORGM)/"*|*"(LODORCT)/"*) exit 0 ;; esac

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-tg5040}"
PAK="$SDCARD/Tools/$PLAT/Lodor.pak"
RUN="$PAK/bin/romm-run"
BIN="$PAK/lodor-sync"
[ -x "$RUN" ] || exit 0

# 1. --push-save is the HYBRID post-game push (A2/A3 fix — this hook previously called --sync-save,
# whose offline path queues NOTHING despite the old comment here claiming otherwise): a changed save
# is pushed and server-VERIFIED; an unchanged save dedups against the server's content_hash (no
# duplicate revision); if the push does NOT land (Wi-Fi off / server down), the save is STAGED into
# pending-saves.txt and the boot daemon / next sync flushes it — no save is ever lost and no fake
# success is ever reported. Post-game wants no pull anyway (the pre-launch hook owns the pull
# direction). This runs FIRST, so the just-played save is pushed while its CURRENT on-disk name
# still matches the launched ROM (the engine uploads the CANONICAL marker-free name — task #126).
"$RUN" --push-save "$HOOK_ROM_PATH" >/dev/null 2>&1
_ssrc=$?
# PAIRING_EXPIRED (task #124): engine exit 6 = token revoked/expired. This hook draws nothing
# (the launcher owns the screen again), so flag it for the Tools-menu banner instead.
if [ "$_ssrc" = 6 ]; then
	: > "${SHARED_USERDATA_PATH:-$SDCARD/.userdata/shared}/Lodor/.pairing-expired" 2>/dev/null
fi

# 2. --reconcile flips the marker and carries the save + cover with the rename. It is filesystem-only
# and OFFLINE, so it is invoked DIRECTLY (not via romm-run, which gates on a live Wi-Fi connection) —
# a downloaded game must get its ✓ even when Wi-Fi is off. No-op for a game that is still a 0-byte stub
# or already marked ✓.
if [ -x "$BIN" ]; then
	# CWD = the shared config home (config.json lives there now, not the pak); LODOR_PAK_DIR keeps
	# engine STATE in the pak. Mirrors romm-run / romm-sync-lib.sh's split.
	CFGD="${SHARED_USERDATA_PATH:-$SDCARD/.userdata/shared}/Lodor"
	[ -d "$CFGD" ] || CFGD="$PAK"
	( cd "$CFGD" 2>/dev/null && \
	  BASE_PATH="$SDCARD" SDCARD_PATH="$SDCARD" PLATFORM="$PLAT" LODOR_PAK_DIR="$PAK" \
	  "$BIN" --reconcile "$HOOK_ROM_PATH" ) >/dev/null 2>&1
fi
exit 0
