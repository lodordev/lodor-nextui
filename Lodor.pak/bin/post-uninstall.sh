#!/bin/sh
# post-uninstall.sh — NextUI Pak Store post_uninstall hook for Lodor (fixes #30).
#
# WHY THIS EXISTS: the store uninstall is `os.RemoveAll(Tools/<plat>/Lodor.pak)` — it deletes ONLY
# the pak dir. But Lodor's credential + pairing state lives OUTSIDE the pak, in NextUI's shared
# userdata (decision 2026-06-30, lib/romm-sync-lib.sh): $SDCARD/.userdata/shared/Lodor/ holds
# config.json (the RomM token + Cloudflare-Access creds), settings.conf, and active-profile.txt.
# Those SURVIVE a store uninstall, leaving live credentials on a card the user thinks is clean.
# Lodor also plants a delivery surface outside the pak (NextUI .hooks, Game Manager / Continue root
# entries, LODORGM/LODORCT emu paks). This hook removes all of that residue.
#
# CONTRACT (store, verified against UncleJunVIP/nextui-pak-store @ main):
#   models/pak.go     Scripts.PostUninstall Script `json:"post_uninstall"` (nested under "scripts");
#                     Script = {path string, args []string}.
#   utils/functions.go RunScript() runs exec.Command(script.Path, script.Args...) with NO cmd.Dir
#                     and NO pak-dir path join. So we cannot rely on CWD or a relative path base —
#                     this script resolves EVERYTHING from the environment / SD root itself, and
#                     "path" in pak.json is the absolute on-card location of this file.
#   NOTE: on the store's current main branch RunScript is defined but not yet wired into the
#   uninstall flow (uninstall = RemoveAll only). This hook is written to be correct the moment the
#   store wires post_uninstall — and harmless meanwhile. It must NEVER fail the uninstall: every
#   op is rm -f / rm -rf, and we always exit 0.
#
# update_ignore is UNRELATED and stays as-is: it preserves config.json/settings.conf across
# UPDATES. This hook only ever runs on UNINSTALL.

# --- resolve SD root + platform the same way the pak does -----------------------------------------
SDCARD="${SDCARD_PATH:-${SD_ROOT:-/mnt/SDCARD}}"
[ -d "$SDCARD" ] || SDCARD="/mnt/SDCARD"

# Credential/pairing home is platform-independent (shared userdata). The delivery surface is
# per-platform; the store only tells us one $PLATFORM (if any), so scan every platform dir we find
# to be robust across tg5040/tg5050 and pre-seeded/cloned cards.
PLATS="${PLATFORM:-}"
for _pd in "$SDCARD/Tools"/* "$SDCARD/Emus"/* "$SDCARD/.userdata"/*; do
	[ -d "$_pd" ] || continue
	_p="$(basename "$_pd")"
	case "$_p" in shared) continue ;; esac
	case " $PLATS " in *" $_p "*) ;; *) PLATS="$PLATS $_p" ;; esac
done

# --- 1) credential + pairing state (THE #30 fix — lives OUTSIDE the pak) ---------------------------
CFG_DIR="$SDCARD/.userdata/shared/Lodor"
# config.json = RomM token + cf_access creds; settings.conf = UI toggles; active-profile.txt = which
# profile. Remove the individual known files first, then the (now-empty) Lodor config dir.
rm -f "$CFG_DIR/config.json" \
      "$CFG_DIR/settings.conf" \
      "$CFG_DIR/active-profile.txt" \
      "$CFG_DIR/catalog-index.json" \
      "$CFG_DIR/mirror-manifest.json" \
      "$CFG_DIR/last-synced.txt" \
      "$CFG_DIR/pending-saves.txt" \
      "$CFG_DIR/pending-states.txt" \
      "$CFG_DIR/lodor-feed.txt" 2>/dev/null
rm -rf "$CFG_DIR" 2>/dev/null

# --- 2) delivery surface + cached artifacts, per platform -----------------------------------------
for _p in $PLATS; do
	[ -n "$_p" ] || continue

	# 2a) the pak dir itself (the store removes this, but be defensive if this runs before RemoveAll
	# or the store call path differs) — plus every cached pairing/sync artifact that lived in it.
	PAKD="$SDCARD/Tools/$_p/Lodor.pak"
	rm -f "$PAKD/config.json" \
	      "$PAKD/settings.conf" \
	      "$PAKD/active-profile.txt" \
	      "$PAKD/catalog-index.json" \
	      "$PAKD/mirror-manifest.json" \
	      "$PAKD/last-synced.txt" \
	      "$PAKD/pending-saves.txt" \
	      "$PAKD/pending-states.txt" \
	      "$PAKD/download-queue.txt" \
	      "$PAKD/lodor-feed.txt" \
	      "$PAKD/.library-seeded" 2>/dev/null

	# 2b) NextUI hook copies Lodor plants under .userdata/<plat>/.hooks (boot.d starts the daemon).
	HOOKS="$SDCARD/.userdata/$_p/.hooks"
	for _hd in pre-launch.d post-launch.d boot.d; do
		for _hf in "$HOOKS/$_hd/"*lodor* "$HOOKS/$_hd/"*-lodor-*; do
			[ -e "$_hf" ] && rm -f "$_hf" 2>/dev/null
		done
	done

	# 2c) Game Manager + Continue "emulator" root entries.
	rm -rf "$SDCARD/Emus/$_p/LODORGM.pak" "$SDCARD/Emus/$_p/LODORCT.pak" 2>/dev/null
done

# 2d) Game Manager + Continue Roms rows (shared across platforms — one Roms tree).
rm -rf "$SDCARD/Roms/Game Manager (LODORGM)" \
       "$SDCARD/Roms/0) Game Manager (LODORGM)" \
       "$SDCARD/Roms/0) Continue (LODORCT)" 2>/dev/null

# a stray daemon from this session, if any (never fatal on hosts without killall).
killall romm-syncd >/dev/null 2>&1 || true

exit 0
