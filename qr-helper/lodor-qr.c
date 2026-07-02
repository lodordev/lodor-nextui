// lodor-qr.c — standalone aarch64 SDL2 QR display for Lodor-NextUI Tailscale QR sign-in.
//
// HOST RENDERING ONLY. It contains NO RomM logic and NO Tailscale logic: it renders a QR
// code for a login URL (+ the raw URL text as a scan fallback) and polls a STATE FILE that
// the pak's shell keeps up to date from `tailscale status`. The pak owns every tunnel /
// RomM decision; this binary only draws pixels and reads one file. It is the pak-side
// substitute for the LodorOS launcher's Lodor_drawQR + Lodor_obTailscaleFlow, which cannot
// be reused because a Tool pak does not own the launcher's SDL surface.
//
// SDL bring-up mirrors NextUI's stock show2.elf (proven on tg5040/tg5050 H700): a 0x0
// SDL_CreateWindow + SDL_GetWindowSurface fullscreen surface, software SDL_FillRect draws,
// SDL_UpdateWindowSurface flip. The font is the same embedded RoundedMplus1c the stock
// show2 uses (no runtime font-path dependency, no bundled font file).
//
// Usage:
//   lodor-qr --url <URL> [--statefile <path>] [--ready <token>] [--title <text>]
//            [--timeout <secs>]
//
// Exit codes (honest, checked by the pak):
//   0  ready token observed in the state file (signed in / connected)
//   2  user cancelled (any button / key / window close)      -> pak ABORTS onboarding
//   3  timed out before the ready token appeared             -> pak ABORTS onboarding
//   4  usage / SDL / TTF init OR render failure (unusable surface, degenerate window) ->
//      the pak treats this (and any crash: 139/134/...) as a RENDER FAILURE and degrades to
//      the text-URL + honest status poll, so sign-in can still complete without the QR.
// These four are kept DISTINCT on purpose: the pak (Lodor.pak launch.sh ts_show_qr) branches
// on them — 0 = done, 2/3 = abort, anything else = text-URL fallback.
//
// Honesty (feedback_no_fake_ui_state): the "Signed in" screen is shown ONLY after the
// state file actually reports the ready token; the "Waiting for sign-in" line reflects the
// real, unresolved state; a cancel/timeout never claims success.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

#include "qrcodegen.h"
#include "embedded_font_rounded.h"

#define RGB_WHITE  0xFFFFFF
#define RGB_BLACK  0x000000
#define BG_COLOR   0x0d1b2a   // same deep navy the pak's show2 screens use

static SDL_Window*  win    = NULL;
static SDL_Surface* screen = NULL;
static TTF_Font*    f_big  = NULL;
static TTF_Font*    f_small= NULL;

static uint32_t mapc(uint32_t rgb) {
	return SDL_MapRGB(screen->format, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

// Draw the QR for `text` as black modules on a white quiet-zone panel, horizontally
// centered, top at top_y, sized to min(max_h, panel width). Returns the panel pixel size
// (so the caller places text under it), or 0 on encode failure. ECC LOW -> smallest
// version -> biggest modules on a small screen. Mirrors Lodor_drawQR from the fork.
static int draw_qr(const char* text, int top_y, int max_h) {
	if (!text || !text[0]) return 0;
	uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
	uint8_t tmp[qrcodegen_BUFFER_LEN_MAX];
	if (!qrcodegen_encodeText(text, tmp, qr, qrcodegen_Ecc_LOW,
			qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true))
		return 0;
	int size = qrcodegen_getSize(qr);
	if (size <= 0) return 0;
	const int quiet = 3;
	int total = size + quiet * 2;
	int pad = 16;
	int availw = screen->w - pad * 2;
	int dim = (max_h < availw) ? max_h : availw;
	if (dim < total) dim = total;
	int mod = dim / total; if (mod < 1) mod = 1;
	int panel = total * mod;
	int px = (screen->w - panel) / 2; if (px < 0) px = 0;
	int py = top_y;
	SDL_FillRect(screen, &(SDL_Rect){ px, py, panel, panel }, mapc(RGB_WHITE));
	int ox = px + quiet * mod, oy = py + quiet * mod;
	uint32_t black = mapc(RGB_BLACK);
	for (int y = 0; y < size; y++)
		for (int x = 0; x < size; x++)
			if (qrcodegen_getModule(qr, x, y))
				SDL_FillRect(screen, &(SDL_Rect){ ox + x * mod, oy + y * mod, mod, mod }, black);
	return panel;
}

// Blit `s` horizontally centered at y in color col using font `fnt`; returns the y just
// below the rendered line (or y unchanged if nothing was drawn).
static int blit_centered(TTF_Font* fnt, const char* s, int y, SDL_Color col) {
	if (!fnt || !s || !s[0]) return y;
	SDL_Surface* t = TTF_RenderUTF8_Blended(fnt, s, col);
	if (!t) return y;
	int x = (screen->w - t->w) / 2; if (x < 0) x = 0;
	SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){ x, y, t->w, t->h });
	int h = t->h; SDL_FreeSurface(t);
	return y + h;
}

// Truncate `src` to at most `maxw` pixels for font `fnt`, appending an ellipsis; result in
// `out`. Keeps a long login URL from overrunning the screen edges.
static void fit_text(TTF_Font* fnt, const char* src, char* out, size_t outsz, int maxw) {
	if (!fnt) { snprintf(out, outsz, "%s", src); return; }
	int w = 0, h = 0;
	if (TTF_SizeUTF8(fnt, src, &w, &h) == 0 && w <= maxw) { snprintf(out, outsz, "%s", src); return; }
	size_t n = strlen(src);
	while (n > 4) {
		char buf[600];
		if (n + 3 >= sizeof(buf)) { n = sizeof(buf) - 4; }
		snprintf(buf, sizeof(buf), "%.*s...", (int)n, src);
		if (TTF_SizeUTF8(fnt, buf, &w, &h) == 0 && w <= maxw) { snprintf(out, outsz, "%s", buf); return; }
		n--;
	}
	snprintf(out, outsz, "%s", src);
}

// Read the trimmed contents of `path` into buf (whitespace-trimmed). Returns 0 on success.
static int read_trim(const char* path, char* buf, size_t sz) {
	buf[0] = '\0';
	if (!path || !path[0]) return -1;
	FILE* fp = fopen(path, "r");
	if (!fp) return -1;
	size_t n = fread(buf, 1, sz - 1, fp);
	fclose(fp);
	buf[n] = '\0';
	// trim leading/trailing whitespace
	char* s = buf;
	while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
	size_t l = strlen(s);
	while (l > 0 && (s[l-1] == ' ' || s[l-1] == '\t' || s[l-1] == '\n' || s[l-1] == '\r')) s[--l] = '\0';
	if (s != buf) memmove(buf, s, l + 1);
	return 0;
}

static TTF_Font* open_font(int px) {
	SDL_RWops* rw = SDL_RWFromConstMem(RoundedMplus1c_Bold_reduced_ttf,
	                                   RoundedMplus1c_Bold_reduced_ttf_len);
	if (!rw) return NULL;
	return TTF_OpenFontRW(rw, 1, px);   // 1 => SDL frees the RWops
}

int main(int argc, char** argv) {
	const char* url       = NULL;
	const char* statefile = NULL;
	const char* ready     = "connected";
	const char* title     = "Sign in to Tailscale";
	int timeout_s = 120;

	for (int i = 1; i < argc; i++) {
		if      (!strcmp(argv[i], "--url")       && i+1 < argc) url       = argv[++i];
		else if (!strcmp(argv[i], "--statefile") && i+1 < argc) statefile = argv[++i];
		else if (!strcmp(argv[i], "--ready")     && i+1 < argc) ready     = argv[++i];
		else if (!strcmp(argv[i], "--title")     && i+1 < argc) title     = argv[++i];
		else if (!strcmp(argv[i], "--timeout")   && i+1 < argc) timeout_s = atoi(argv[++i]);
	}
	if (!url || !url[0]) { fprintf(stderr, "lodor-qr: --url is required\n"); return 4; }
	if (timeout_s <= 0) timeout_s = 120;

	// VIDEO is the only hard requirement. JOYSTICK is initialised SEPARATELY and best-effort:
	// stock show2.elf inits VIDEO only, and a joystick-subsystem failure must NOT abort the QR
	// (cancel-by-button is a nicety; the authoritative connect signal is the state file). Folding
	// JOYSTICK into the critical SDL_Init was a latent way to fail the whole helper on a device
	// whose evdev/joystick layer hiccups.
	if (SDL_Init(SDL_INIT_VIDEO) < 0) {
		fprintf(stderr, "lodor-qr: SDL_Init(VIDEO) failed: %s\n", SDL_GetError());
		return 4;
	}
	SDL_ShowCursor(0);
	// Open every joystick so a controller button counts as cancel (best-effort; the
	// authoritative connect signal is the state file, never a button). Non-fatal on failure.
	if (SDL_InitSubSystem(SDL_INIT_JOYSTICK) == 0) {
		int njoy = SDL_NumJoysticks();
		for (int i = 0; i < njoy; i++) SDL_JoystickOpen(i);
	}

	// Window bring-up mirrors NextUI's stock show2.elf EXACTLY (proven on tg5040/tg5050): a
	// 0x0 SDL_CreateWindow that the TrimUI MALI/fbdev SDL2 forces to the real display size, then
	// a software SDL_GetWindowSurface. Deviating from this (fullscreen flags / explicit dims)
	// risks breaking the known-good path, so we DON'T — we only add an honest guard below.
	win = SDL_CreateWindow("", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
	                       0, 0, SDL_WINDOW_SHOWN);
	if (!win) { fprintf(stderr, "lodor-qr: SDL_CreateWindow failed: %s\n", SDL_GetError()); SDL_Quit(); return 4; }
	screen = SDL_GetWindowSurface(win);
	// Guard a degenerate surface: if the window came up 0x0 (or with no pixel format), every
	// draw would silently no-op and the user would stare at ~120s of nothing. Bail with the
	// render-failure code so the pak degrades to the text-URL path instead of a dead screen.
	if (!screen || !screen->format || screen->w <= 0 || screen->h <= 0) {
		fprintf(stderr, "lodor-qr: unusable window surface (%dx%d)\n",
		        screen ? screen->w : 0, screen ? screen->h : 0);
		SDL_Quit();
		return 4;
	}

	if (TTF_Init() < 0) { fprintf(stderr, "lodor-qr: TTF_Init failed: %s\n", TTF_GetError()); SDL_Quit(); return 4; }
	// Scale font to the panel height so it reads on both the Brick (1024x768) and Smart Pro.
	int base = screen->h > 0 ? screen->h : 720;
	int big_px   = base / 22; if (big_px   < 20) big_px   = 20; if (big_px   > 40) big_px = 40;
	int small_px = base / 32; if (small_px < 14) small_px = 14; if (small_px > 28) small_px = 28;
	f_big   = open_font(big_px);
	f_small = open_font(small_px);
	if (!f_small) f_small = f_big;

	SDL_Color white = { 255, 255, 255, 255 };
	SDL_Color gray  = { 170, 180, 190, 255 };
	SDL_Color green = { 120, 220, 140, 255 };

	char urlline[600];
	fit_text(f_small, url, urlline, sizeof(urlline), screen->w - 32);

	uint32_t start = SDL_GetTicks();
	uint32_t last_check = 0;
	int rc = 3;                 // default: timeout
	char state[256];
	int connected = 0;
	int dots = 0, dotframe = 0;

	while (1) {
		uint32_t now = SDL_GetTicks();
		if ((int)((now - start) / 1000) >= timeout_s) { rc = 3; break; }

		// input: any button / key / window-close cancels.
		SDL_Event ev;
		int cancel = 0;
		while (SDL_PollEvent(&ev)) {
			if (ev.type == SDL_QUIT) cancel = 1;
			else if (ev.type == SDL_KEYDOWN) cancel = 1;
			else if (ev.type == SDL_JOYBUTTONDOWN) cancel = 1;
			else if (ev.type == SDL_CONTROLLERBUTTONDOWN) cancel = 1;
		}
		if (cancel) { rc = 2; break; }

		// poll the state file ~every 400ms.
		if (last_check == 0 || now - last_check >= 400) {
			last_check = now;
			if (statefile && read_trim(statefile, state, sizeof(state)) == 0) {
				if (state[0] && strstr(state, ready)) connected = 1;
			}
		}
		if (connected) { rc = 0; break; }

		// draw
		SDL_FillRect(screen, NULL, mapc(BG_COLOR));
		int y = screen->h / 16; if (y < 12) y = 12;
		y = blit_centered(f_big, title, y, white);
		y += 8;
		int qmax = screen->h - y - (small_px * 5 + 30);
		if (qmax < 80) qmax = 80;
		int panel = draw_qr(url, y, qmax);
		y += (panel > 0 ? panel : 0) + 10;
		if (panel <= 0) y = blit_centered(f_big, "(couldn't render the QR - use the link)", y, white);
		y = blit_centered(f_small, "Scan with your phone to sign in", y, white);
		y = blit_centered(f_small, urlline, y, gray);
		y = blit_centered(f_small, "If it won't scan, open login.tailscale.com", y, gray);
		if (++dotframe >= 8) { dotframe = 0; dots = (dots + 1) % 4; }
		char wait[32]; snprintf(wait, sizeof(wait), "Waiting for sign-in%.*s", dots, "...");
		blit_centered(f_small, wait, y + 6, gray);
		SDL_UpdateWindowSurface(win);
		SDL_Delay(60);
	}

	if (rc == 0) {
		// Honest success screen — only reached after the state file reported the token.
		SDL_FillRect(screen, NULL, mapc(BG_COLOR));
		int y = screen->h / 3;
		y = blit_centered(f_big, "Signed in to Tailscale", y, green);
		blit_centered(f_small, "Connecting to your RomM server...", y + 10, white);
		SDL_UpdateWindowSurface(win);
		SDL_Delay(900);
	}

	if (f_small && f_small != f_big) TTF_CloseFont(f_small);
	if (f_big) TTF_CloseFont(f_big);
	TTF_Quit();
	SDL_Quit();
	return rc;
}
