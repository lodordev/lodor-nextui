# shellcheck shell=sh
# shellcheck disable=SC2154  # PICK_LST / LISTBIN / pick() are launch.sh's picker contract —
#                              this lib is sourced AFTER they exist and only called from there
# (sourced library — no shebang; the sourcing script sets the shell)
# ui-list.sh (NextUI) — full-screen selected-game cover art behind the game lists (WS-B).
#
# minui-list (0.13.0, the bundled tg5040/tg5050 binaries — verified via strings on a live card)
# accepts a JSON item list where each item may carry features.background_image: an ABSOLUTE
# image path drawn FULL-SCREEN behind the list while that item is selected. There is no
# row-thumbnail mode — this is the native NextUI pattern (the stock launcher does exactly
# this with the selected game's cover). So the Game Manager game list and the Search results
# list feed minui-list JSON items whose background is the game's own cover art:
#     Roms/<System>/.media/<rom-basename>.png     (basename = on-disk filename sans extension;
#                                                  the engine writes + renames these covers)
#
# JSON invocation contract (verbatim from the binary):
#     minui-list --format json --item-key items --file <json> \
#                --write-value state --write-location <out>
#     <json> = {"items":[{"name":"<display>","features":{"background_image":"<abs path>"}},...]}
#     <out>  = a state JSON whose top-level "selected" integer is the 0-BASED INDEX of the
#              chosen item (json mode returns the index, NOT the name).
# Exit codes are the same as text mode: 0 picked, 2 back (B), 3 menu, other = render fail.
#
# Contract (mirrors pick() so callers keep their exact rc case arms):
#     ui_list_json <title> <confirm-text> <paths-file>
#         Display lines are already in $PICK_LST (one per line, the SAME file the text list
#         would draw — raw on-disk names, marker included). <paths-file> holds the parallel
#         FULL rom path per line (same order, same count). On success:
#             PICK_VAL = the raw $PICK_LST line for the chosen index (the exact value the
#                        text path would have returned — callers' path math is unchanged)
#             PICK_IDX = 1-based line number of the choice (0 = answer came from the text
#                        fallback; callers with an ids file use it for dup-proof mapping)
#         Return: 0 picked / 2 back / 3 menu — identical to pick().
#
# Display names: the JSON name is the CLEAN display name — the leading ✘/✓ (legacy [^]/[v])
# download-state marker is browser chrome baked into the on-disk filename, stripped for
# display (same rule as ctpak's strip_marker / the pre-launch hooks). Selection comes back
# as an index, so the display name never has to round-trip to a path — PICK_VAL stays the
# RAW line and gm_actions keeps receiving the real on-disk name.
#
# Graceful degradation (MANDATORY — never blank, never trap the user):
#   a. game with no .media cover      -> plain {"name":...} item (listed, no background)
#   b. building/invoking/parsing the json path fails for ANY reason
#      (item/path count mismatch, temp write fails, minui-list exits outside 0/2/3,
#       rc=0 but no parsable "selected", index out of range)
#                                     -> FALL BACK to the caller's proven --format text
#                                        invocation (pick()) — the menu ALWAYS works
#   c. an old bundled minui-list that chokes on --format json exits nonzero -> same
#      fallback as (b); rc 2/3 are honest user actions (back/menu) and return AS-IS —
#      a back-press must never re-open the same menu as text.

PICK_JSON="/tmp/lodor-setup-pick-json"
PICK_JOUT="/tmp/lodor-setup-pick-jout"
PICK_IDX=0

_UIL_TAB="$(printf '\t')"

# _json_escape <s> -> _UIL_ESC: JSON-string-escaped (backslash, double-quote, tab — the only
# escapables that survive FAT32 filenames; no JSON tool exists on-device so this is pure sh).
# Fast path: nothing to escape (the overwhelming case) costs one `case`, no forks.
_json_escape() {
	_UIL_ESC="$1"
	case "$_UIL_ESC" in
		*[\\\"]*|*"$_UIL_TAB"*) ;;
		*) return 0 ;;
	esac
	_uil_in="$1"; _UIL_ESC=""
	while [ -n "$_uil_in" ]; do
		_uil_c="${_uil_in%"${_uil_in#?}"}"
		_uil_in="${_uil_in#?}"
		case "$_uil_c" in
			\\)         _UIL_ESC="$_UIL_ESC\\\\" ;;
			\")         _UIL_ESC="$_UIL_ESC\\\"" ;;
			"$_UIL_TAB") _UIL_ESC="$_UIL_ESC\\t" ;;
			*)          _UIL_ESC="$_UIL_ESC$_uil_c" ;;
		esac
	done
	return 0
}

# _uil_strip_marker <line> -> _UIL_DSP: display line minus a leading download-state marker
# ("✘ "/"✓ ", legacy "[^] "/"[v] ") — same chrome rule as the hooks/ctpak.
_uil_strip_marker() {
	_UIL_DSP="$1"
	case "$_UIL_DSP" in
		"✘ "*)   _UIL_DSP="${_UIL_DSP#"✘ "}" ;;
		"✓ "*)   _UIL_DSP="${_UIL_DSP#"✓ "}" ;;
		"[^] "*) _UIL_DSP="${_UIL_DSP#"[^] "}" ;;
		"[v] "*) _UIL_DSP="${_UIL_DSP#"[v] "}" ;;
	esac
	return 0
}

# _uil_build <paths-file> -> $PICK_JSON. Nonzero on any shape problem (triggers text fallback).
_uil_build() {
	_uil_n1="$(wc -l < "$PICK_LST" 2>/dev/null)" || return 1
	_uil_n2="$(wc -l < "$1" 2>/dev/null)" || return 1
	[ "$_uil_n1" -gt 0 ] 2>/dev/null || return 1
	[ "$_uil_n1" = "$_uil_n2" ] || return 1
	{
		printf '{"items":[\n'
		_uil_sep=""
		while IFS= read -r _uil_nm <&3 && IFS= read -r _uil_p <&4; do
			_uil_strip_marker "$_uil_nm"
			_json_escape "$_UIL_DSP"; _uil_jn="$_UIL_ESC"
			# cover = <romdir>/.media/<on-disk basename sans extension>.png (engine-written;
			# the reconcile rename carries it, so the cover name tracks the ✘/✓ marker)
			_uil_d="${_uil_p%/*}"
			_uil_b="${_uil_p##*/}"; _uil_b="${_uil_b%.*}"
			_uil_cov="$_uil_d/.media/$_uil_b.png"
			if [ -s "$_uil_cov" ]; then
				_json_escape "$_uil_cov"
				printf '%s{"name":"%s","features":{"background_image":"%s"}}\n' \
					"$_uil_sep" "$_uil_jn" "$_UIL_ESC"
			else
				printf '%s{"name":"%s"}\n' "$_uil_sep" "$_uil_jn"
			fi
			_uil_sep=","
		done 3< "$PICK_LST" 4< "$1"
		printf ']}\n'
	} > "$PICK_JSON" 2>/dev/null || return 1
	return 0
}

ui_list_json() {	# <title> <confirm-text> <paths-file> — see contract above
	PICK_IDX=0
	rm -f "$PICK_JOUT"
	# no renderer / no usable path data -> the text path owns the honest degrade already
	if [ ! -x "$LISTBIN" ] || [ ! -s "${3:-}" ]; then pick "$1" "$2"; return $?; fi
	if ! _uil_build "$3"; then pick "$1" "$2"; return $?; fi
	killall minui-presenter >/dev/null 2>&1 || true
	# shellcheck disable=SC2046  # ui_theme_args: additive theme flags, deliberately word-split
	"$LISTBIN" $(ui_theme_args) --disable-auto-sleep --file "$PICK_JSON" \
		--format json --item-key items \
		--title "$1" --confirm-text "$2" --cancel-text "BACK" \
		--write-value state --write-location "$PICK_JOUT"
	_uil_rc=$?
	case "$_uil_rc" in
		2|3) PICK_VAL=""; return "$_uil_rc" ;;   # honest back/menu — NOT a failure, no fallback
		0)
			_uil_sel="$(sed -n 's/.*"selected"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
				"$PICK_JOUT" 2>/dev/null | head -1)"
			if [ -n "$_uil_sel" ]; then
				PICK_IDX=$((_uil_sel + 1))
				PICK_VAL="$(sed -n "${PICK_IDX}p" "$PICK_LST" 2>/dev/null)"
				[ -n "$PICK_VAL" ] && return 0
			fi
			PICK_IDX=0 ;;    # rc=0 but unparsable/out-of-range output -> garbage -> fallback
		*) : ;;              # render failure OR an old binary choking on --format json
	esac
	command -v log >/dev/null 2>&1 && log "minui-list json path failed (rc=$_uil_rc) - falling back to text list"
	pick "$1" "$2"
}
