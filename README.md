# Lodor for NextUI

Lodor's RomM sync layer as a **NextUI Tool pak + launch hooks** — no NextUI fork. NextUI is plugged
into, never patched: the engine (`lodor-sync`, the same arm64 binary LodorOS ships) owns all RomM
logic; NextUI only renders and shells out. Everything here is host delivery (pak shell + hooks).

## Supported devices

NextUI's own live build targets only: **tg5040 (TrimUI Brick / TrimUI Smart Pro) and tg5050 (TrimUI
Smart Pro S)** — both arm64, so a single `GOARCH=arm64` engine binary serves both. `my355` was a
NextUI target historically but has been removed upstream (it went `_unmaintained`, then dropped from
the tree) and is intentionally not built here. Any other device → use LodorOS (the MinUI fork), not
this.

## Packaging

**One self-onboarding Tool pak per device: `Lodor.pak`.** On first open (no config.json / token yet)
it runs the on-device onboarding wizard (server URL → pairing code → device name, via the on-screen
`minui-keyboard`); once configured it runs the normal client (Tools menu + hooks + background daemon),
with a **`Setup / Re-pair`** menu entry to re-run the wizard if you mis-paired or change servers. The
old separate `Lodor Setup.pak` has been folded in and removed — there is now a single Tools-menu
entry. `assemble.sh` stages `Lodor.pak` for `tg5040` and `tg5050`.

## What this delivers (and what it inherits from NextUI)

| Capability | How |
|---|---|
| Download-on-launch | `hooks/pre-launch.d/10-lodor-fetch.sync.sh` (`.sync.sh` ⇒ synchronous; nextui.elf has exited, framebuffer free) → engine `--download` |
| Save bracket (pull-before / push-after) | pre-launch restore picker + `hooks/post-launch.d/90-lodor-pushsave.sh` (`--sync-save` then `--reconcile`) |
| Boot daemon (periodic flush) | `hooks/boot.d/10-lodor.sh` detaches `bin/romm-syncd` |
| Onboarding / pairing | Built into `Lodor.pak/launch.sh` — self-onboarding wizard on first open (and via the `Setup / Re-pair` menu entry): `--set-server` -> `--pair` -> `--register-device` via the on-screen `minui-keyboard`. Writes config.json to the shared config home; preserves a pre-seeded `cf_access` block for Cloudflare-Access-gated servers. |
| Tools menu | `launch.sh` — Sync now / Refresh library / Download queue / Download BIOS / Recent activity / Switch User / Coexist toggle / Setup - Re-pair |
| System list, box-art, resume, Wi-Fi UI, on-screen keyboard, **RetroAchievements**, Collections render, theming, search | **Inherited from NextUI** — not reimplemented |

The launch hooks are a verified NextUI contract (HOOKS.md + `bin/run_hooks.sh` on current tip):
`$USERDATA_PATH/.hooks/{boot,pre-launch,post-launch}.d/`, `HOOK_TYPE`/`HOOK_ROM_PATH` env, `.sync.sh`
runs synchronously, background hooks are `wait`ed. `launch.sh` self-installs these hooks on first run.

## Resolved design decisions (2026-06-30)

1. **config.json / settings.conf / active-profile.txt live under `$SHARED_USERDATA_PATH/Lodor`**
   (= `$SDCARD/.userdata/shared/Lodor`), NOT in the pak — they survive a pak reinstall and are shared
   across NextUI profiles. The engine reads them CWD-relative, so the pak `cd`s into that dir before
   exec; engine STATE (catalog-index.json / pending-saves.txt / download-queue.txt) still follows
   `LODOR_PAK_DIR` (the pak). The engine binary is unchanged. A one-time, non-destructive migration
   (`lodor_migrate_cfg`) moves any legacy in-pak config into the shared dir.
2. **RetroAchievements is deferred to NextUI native.** NextUI owns RA (login + creds in
   `ra_auth.c`/`config.c`). The engine's `--ra-login` stays a LodorOS-only path; it is deliberately
   NOT surfaced in this menu so two RA configs can never fight.
3. **Collections format is byte-compatible with NextUI native** — verified against `getCollection()`:
   `$SDCARD/Collections/<name>.txt`, one member per line as an SDCARD-relative path WITH a leading
   `/` (NextUI concatenates `SDCARD_PATH + line`), `\n`-joined. The engine's `--mirror-collections`
   already emits exactly this. No change needed.

## Assembly

`assemble.sh` builds the engine from the current monorepo HEAD and stages
`Tools/{tg5040,tg5050}/Lodor.pak`. Third-party host-render binaries (`minui-list`,
`minui-presenter`, `minui-keyboard`), `7zz`, and the CA bundle are dropped at assemble time — they
are NOT committed here (binary / non-redistributable provenance). Heavy emulator paks (N64/DC/PSP/SS
wrapped with the save-sync `launch.sh`) stay card-side / private (non-redistributable cores + BYOB)
and are not part of this tree.

## Tailscale QR sign-in (tg5040 / tg5050)

Onboarding can reach a RomM server over your own private **Tailscale** network with a
**scan-a-QR** sign-in — no auth-key file, no store pak. On first open the wizard asks *"How
will you reach RomM?"*; choosing **Tailscale (sign in with QR)** brings up a **userspace**
`tailscaled` (SOCKS5 proxy, no `/dev/net/tun`, no root), runs an interactive `tailscale up`
(no `--authkey`), and renders the `login.tailscale.com` URL as a QR (plus the raw URL as a
scan fallback). Scan it with your phone, approve the node, and the wizard continues to the
normal server-URL + pairing steps — the server is a MagicDNS `http://name` and the engine
routes every RomM call through the SOCKS5 proxy (`socks5_proxy` + `tier` on the host in
`config.json`).

- **Bundled:** static aarch64 `tailscaled` + `tailscale` (official v1.94.1, `bin/tailscale/`)
  and a standalone SDL QR helper (`bin/<device>/lodor-qr`, built from `qr-helper/` with the
  vendored Nayuki `qrcodegen` + the same embedded font NextUI's `show2` uses). **NextUI is
  NOT forked** — the QR is drawn by the pak's own helper, never a launcher patch.
- **Runtime:** `romm-run` / the boot daemon bring the tunnel up (reusing the persisted login)
  whenever `config.json` is a tier-1 host; a LAN / public-URL config is untouched.
- **Maintenance:** the client menu gains **Tailscale status** and **Tailscale: Reset &
  forget** (wipes the saved login for a clean re-sign-in). Only surfaced on tg5040 / tg5050.
