# shellcheck shell=sh
# (sourced library — no shebang; the sourcing script sets the shell)
# ui-theme.sh (NextUI) — inherit the USER'S NextUI look on every Lodor screen (WS-A).
#
# NextUI lets the user install a custom font and wallpaper; a Tool pak drawn by minui-list /
# minui-presenter otherwise paints the BUNDLED default font on a plain background — the single
# biggest "this isn't part of my OS" tell. Both tools accept (verified: minui-list 0.13.0,
# minui-presenter 0.12.0, and their current upstream option tables). Paths CONFIRMED from a
# live NextUI card (2026-07-11), NOT guessed:
#     --font-default <ttf>       draw text with this font
#     --background-image <png>   draw over this image
# so passing the user's own files makes every Lodor screen match the rest of the device.
#
# minui-keyboard does NOT accept these flags (verified against josegonzalez/minui-keyboard's
# option table 2026-07-11: only --initial-value/--title/--write-location/--disable-auto-sleep/
# --show-hardware-group). getopt_long fails the whole parse on an unknown long option, which
# would kill the keyboard — NEVER thread these args into $KBBIN.
#
# Contract:
#   ui_theme_args    echo additive flags for theme files that EXIST; nothing otherwise.
#                    Resolved once per process and cached. Callers expand it UNQUOTED —
#                    `"$LISTBIN" $(ui_theme_args) ...` — so an empty result contributes
#                    zero argv words and every call renders exactly as before.
#   ui_theme_accent  reserved (empty until the accent probe lands — see TODO below).
#
# Word-splitting safety: the flags are space-joined inside one string, so any candidate path
# that itself contains whitespace would split into broken argv — such candidates are SKIPPED
# (guard only: $SDCARD is /mnt/SDCARD on-device and the .userdata/shared names carry no
# spaces, so this never fires in practice).
#
# Degrade: no font/wallpaper installed, lib missing, or paths unreadable -> zero flags ->
# today's exact rendering. This helper must never break a draw.

UI_THEME_RESOLVED=0
UI_THEME_ARGS=""

# _ui_theme_usable <path> — a real, non-empty file whose path is safe to expand unquoted.
_ui_theme_usable() {
	case "$1" in *[[:space:]]*) return 1 ;; esac
	[ -f "$1" ] && [ -s "$1" ]
}

ui_theme_args() {
	if [ "$UI_THEME_RESOLVED" != 1 ]; then
		UI_THEME_RESOLVED=1
		UI_THEME_ARGS=""
		_uts="${SDCARD:-${SDCARD_PATH:-/mnt/SDCARD}}"
		# Font (CONFIRMED from a live NextUI card 2026-07-11): the user's active font is
		# .system/res/font<N>.ttf where N = the `font=` value in .userdata/shared/minuisettings.txt
		# (font1.ttf = "Next", font2.ttf = "OG"; default 1). Fall back to font1 then a wildcard.
		_utms="$_uts/.userdata/shared/minuisettings.txt"
		_utn=$(sed -n 's/^font=//p' "$_utms" 2>/dev/null | head -1)
		case "$_utn" in ''|*[!0-9]*) _utn=1 ;; esac
		for _utf in "$_uts/.system/res/font${_utn}.ttf" "$_uts/.system/res/font1.ttf" \
			"$_uts/.system/res/"*.ttf; do
			if _ui_theme_usable "$_utf"; then
				UI_THEME_ARGS="--font-default $_utf"
				break
			fi
		done
		# Wallpaper (CONFIRMED from a live card): NextUI's active background is
		# .system/res/background.png. Legacy root bg.png kept as a fallback.
		for _utb in "$_uts/.system/res/background.png" "$_uts/bg.png"; do
			if _ui_theme_usable "$_utb"; then
				UI_THEME_ARGS="${UI_THEME_ARGS:+$UI_THEME_ARGS }--background-image $_utb"
				break
			fi
		done
	fi
	printf '%s' "$UI_THEME_ARGS"
}

# ui_theme_accent — reserved. The accent source IS now known: .userdata/shared/minuisettings.txt
# carries color1..color7 as 0xRRGGBB (accent = color2, background = color3). But minui-list's
# only color flag is --background-color, and background.png (WS-A) already owns the background
# on stock cards — so setting --background-color would either be ignored (image wins) or, when
# no image exists, could clash with the user's actual scheme. Font + wallpaper inheritance are
# the confirmed, safe, high-value levers; accent stays OFF until there is a call site where a
# solid accent color genuinely improves the look without fighting the wallpaper. Kept empty
# deliberately (never guess-paint a screen).
ui_theme_accent() { :; }
