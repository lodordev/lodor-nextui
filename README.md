# Lodor for NextUI

**Your RomM library, on stock NextUI.** Lodor-NextUI adds two-way save sync and download-on-launch for your self-hosted [RomM](https://romm.app) server to a **stock [NextUI](https://github.com/LoveRetro/NextUI)** install — delivered as an ordinary NextUI **Tool pak**. There is **no NextUI fork and no patched firmware**: NextUI is plugged into, never modified. All RomM logic lives in the [Lodor engine](https://github.com/lodordev/lodor); the pak only draws menus and shells out.

You keep your ROMs and saves on your server. The handheld holds only what you're playing, and NextUI does everything it already does — box art, resume, Wi-Fi, on-screen keyboard, RetroAchievements, Collections — untouched.

> **Status: beta (0.9.1).** Onboarding (including Tailscale QR sign-in), pairing, download-on-launch, and save sync have had a hardware pass on `tg5040`. `tg5050` reuses the same arm64 build and NextUI userland but has not had its own hardware pass yet.

## What it adds

- **Whole-library browsing** — every game in your RomM collection appears as a lightweight stub with box art, even offline.
- **Download-on-launch** — open a game you don't have yet; it downloads with a real progress bar, verifies, and boots. Failures are honest: the game stays in your library and relaunching retries.
- **Two-way save sync** — saves pull before you play and push after you quit, automatically. Browse and restore older server saves.
- **Continue** — your recent games from all your devices, as a normal NextUI collection.
- **Game Manager** — per-game download / delete / save actions from the top of your games list.
- **On-device onboarding** — server URL, pairing code, device name, all on the handheld; built-in **Tailscale sign-in by QR code**, Cloudflare Access service tokens, or plain LAN.
- **Merges into your folders** — by default RomM games land in your existing `Roms/` folders, tracked by a safety manifest; your own files are never modified, and **Remove Lodor from this card** uninstalls cleanly.

## Requirements

- A **TrimUI Brick / Smart Pro (`tg5040`)** or **TrimUI Smart Pro S (`tg5050`)** already running **stock NextUI**.
- A **RomM server, 4.8.0 or newer** (device pairing ships in stock RomM as of 4.8.0), reachable by LAN/public URL, Tailscale, or Cloudflare Access.

## Install

1. Download `Lodor-NextUI-0.9.1-beta.zip` from [Releases](https://github.com/lodordev/lodor-nextui/releases).
2. Unzip it to the **root of your NextUI SD card**, merging the zip's `Tools/`, `Emus/`, and `Roms/` folders with the ones already on the card (use a real unzip, not a Finder/Explorer drag — executable bits matter).
3. Reinsert the card, boot NextUI, open **Tools → Lodor** — the first open runs onboarding.

Full docs — installation, onboarding, Tailscale/Cloudflare setup, troubleshooting — live in the [wiki](https://github.com/lodordev/lodor-nextui/wiki).

Alternatively, `Lodor.pak.zip` (also on Releases) is just the Tool pak for pak-store-style installs into `Tools/<platform>/Lodor.pak/` — one pak serves both platforms.

## What's in this repo

This repo is the pak's **source**: everything scripted and buildable, no big binaries.

| Path | What |
|---|---|
| `Lodor.pak/` | The Tool pak — `launch.sh` (menus, onboarding wizard), `lib/`, launch `hooks/`, the Game Manager (`gmpak/`) and Continue (`ctpak/`) root entries, CA bundle |
| `assemble.sh` | Builds the engine and stages the complete pak for `tg5040` + `tg5050` |
| `qr-helper/` | Source for `lodor-qr`, the small SDL helper that draws the Tailscale sign-in QR on screen |
| `test/` | Off-device test harness — wizard/menu simulation against stubbed binaries, 146 scenarios (`test/run-all.sh`) |
| `pak.json` | Pak metadata |

The release zip is assembled from this tree plus binaries that are **not** committed here:

- **`lodor-sync`** — the Lodor engine, built from [lodordev/lodor](https://github.com/lodordev/lodor) (Go, CGO-free, arm64).
- **`tailscaled` / `tailscale`** — official Tailscale **1.94.1** static arm64 builds, unmodified.
- **`minui-list` / `minui-presenter` / `minui-keyboard`** — [josegonzalez](https://github.com/josegonzalez)'s host-render tools, unmodified.
- **`7zz`** — 7-Zip's official Linux arm64 build, for archive extraction.
- **`lodor-qr`** — built from `qr-helper/` in this repo (vendors [Project Nayuki's QR Code generator](https://github.com/nayuki/QR-Code-generator), MIT).

## License

MIT (this repo's scripts and sources). NextUI, MinUI, Tailscale, RomM, and the bundled third-party tools are their authors' work under their own licenses — see the [Credits](https://github.com/lodordev/lodor-nextui/wiki/Credits) page.
