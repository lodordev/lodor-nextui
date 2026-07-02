// rootscan/main.c — drives the VERBATIM-extracted NextUI root scan (see run.sh)
// against the replica card tree and asserts BOTH Lodor root rows: Game Manager
// visibility, RELATIVE ORDER and DISPLAY NAME (task #128/#131 presence; #134
// bottom sort via the Roms/map.txt NBSP alias) and the one-press Continue row
// (#134: digit-prefix TOP sort, clean display, optional dynamic map.txt label).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <ctype.h>
#include <dirent.h>
#include "defines.h"
#include "utils.h"

#include "gen/containers.c"
#include "gen/hasEmu.c"
#include "gen/hasRoms.c"
#include "gen/getRoms.c"

// The heal-written map.txt alias: U+00A0 NBSP + "Game Manager". strcasecmp is
// bytewise, 0xC2 > every ASCII letter => sorts LAST; trimSortingMeta only strips
// digit prefixes, so the alias reaches the renderer intact and NBSP draws as a
// blank space-width glyph in both shipped fonts (font1/font2 cmap-verified).
#define GM_ALIAS "\xC2\xA0Game Manager"

static int idx_of(Array* entries, const char* tag) {
	for (int i = 0; i < entries->count; i++) {
		Entry* e = entries->items[i];
		if (strstr(e->path, tag)) return i;
	}
	return -1;
}

// argv[1]: "present" (default) — full shipped layout: GM row survives, sorts LAST
//                                (after the PS control), aliased display intact;
//                                Continue row FIRST (index 0), displays "Continue";
//          "absent"            — the scan drops GM (negative phases: run.sh removes
//                                one precondition at a time, on-device symptom repro);
//          "nomap"             — map.txt missing: GRACEFUL DEGRADE — GM row present,
//                                display "Game Manager", alphabetical (GBA < GM < PS);
//                                Continue STILL first (digit prefix needs no map);
//          "ctlabel"           — map.txt carries the ENGINE's dynamic Continue label
//                                ("0) Continue (LODORCT)\t0) Continue: Zelda"): row
//                                still index 0, displays "Continue: Zelda" post-trim.
int main(int argc, char** argv) {
	const char* mode = (argc > 1) ? argv[1] : "present";
	printf("SDCARD_PATH=%s PLATFORM=%s mode=%s\n", SDCARD_PATH, PLATFORM, mode);

	// unit probes on the exact on-card folder name
	char* gm = "Game Manager (LODORGM)";
	char emu[MAX_PATH];
	getEmuName(gm, emu);
	char disp[MAX_PATH];
	getDisplayName(gm, disp);
	printf("hide('%s')          = %d (want 0)\n", gm, hide(gm));
	printf("getEmuName('%s')    = '%s' (want LODORGM)\n", gm, emu);
	printf("getDisplayName      = '%s'\n", disp);
	printf("hasEmu('%s')        = %d\n", emu, hasEmu(emu));
	printf("hasRoms('%s')       = %d\n", gm, hasRoms(gm));

	// the actual root scan (includes the Roms/map.txt alias + resort logic verbatim)
	Array* entries = getRoms();
	for (int i = 0; i < entries->count; i++) {
		Entry* e = entries->items[i];
		char* shown = e->name;
		trimSortingMeta(&shown);
		printf("root row %d: display='%s'  (name='%s' path='%s')\n", i, shown, e->name, e->path);
	}
	int gm_i  = idx_of(entries, "(LODORGM)");
	int ct_i  = idx_of(entries, "(LODORCT)");
	int gba_i = idx_of(entries, "(GBA)");
	int ps_i  = idx_of(entries, "(PS)");
	int n64_i = idx_of(entries, "(N64)");
	int fails = 0;
	#define REQ(cond, why) if (!(cond)) { printf("ASSERT FAIL: %s\n", why); fails++; }

	// controls in every mode: mapped systems present, orphan (no Emu pak) filtered
	REQ(gba_i >= 0, "GBA control row missing");
	REQ(ps_i  >= 0, "PS control row missing");
	REQ(n64_i < 0,  "orphan N64 folder (no Emu pak) must be filtered");
	REQ(gba_i < ps_i, "alphabetical control broken: GBA must precede PS");

	// Continue row (task #134): every mode with the folder staged (all of them) must
	// show it FIRST — the digit prefix is the sort key with or without map.txt.
	REQ(ct_i == 0, "Continue must be the FIRST root row");
	if (ct_i >= 0) {
		Entry* ce = entries->items[ct_i];
		char* cshown = ce->name;
		trimSortingMeta(&cshown);
		if (strcmp(mode, "ctlabel") == 0) {
			REQ(strcmp(cshown, "Continue: Zelda") == 0, "ctlabel: Continue must display 'Continue: Zelda'");
		} else {
			REQ(strcmp(cshown, "Continue") == 0, "Continue display must be plain 'Continue'");
		}
	}

	if (strcmp(mode, "absent") == 0) {
		REQ(gm_i < 0, "GM row present but a precondition was removed");
	} else if (strcmp(mode, "nomap") == 0) {
		REQ(gm_i >= 0, "GM row missing (nomap)");
		if (gm_i >= 0) {
			Entry* e = entries->items[gm_i];
			char* shown = e->name;
			trimSortingMeta(&shown);
			REQ(strcmp(shown, "Game Manager") == 0, "nomap display must be plain 'Game Manager'");
			REQ(gba_i < gm_i && gm_i < ps_i, "nomap: GM must sort alphabetically (GBA < GM < PS)");
		}
	} else { // present / ctlabel (full layout; ctlabel only changes the Continue alias)
		REQ(gm_i >= 0, "GM row missing (present)");
		if (gm_i >= 0) {
			Entry* e = entries->items[gm_i];
			REQ(gm_i == entries->count - 1, "GM must be the LAST root row (NBSP alias sort)");
			REQ(gm_i > ps_i, "GM must sort after the PS control");
			REQ(strcmp(e->name, GM_ALIAS) == 0, "GM name must be the exact NBSP alias bytes");
			char* shown = e->name;
			trimSortingMeta(&shown);
			REQ(strcmp(shown, GM_ALIAS) == 0, "trimSortingMeta must NOT eat the NBSP alias");
		}
	}

	if (fails == 0) { printf("ROOTSCAN PASS (%s)\n", mode); return 0; }
	printf("ROOTSCAN FAIL (%s): %d assertion(s)\n", mode, fails);
	return 1;
}
