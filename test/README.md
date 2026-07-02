# wizard-sim — off-device test harness for the NextUI Lodor.pak shell flows

Every UI/flow bug that shipped in this pak (the wizard network-choice loop that trapped Wi-Fi-less
users, the lodor-qr crash that killed onboarding) was catchable without hardware: `launch.sh` and
the libs are POSIX shell — only the *binaries* are aarch64. This harness runs the **real**
`launch.sh` + `lib/*.sh` on any x86 box with stub binaries and scripted answers.

## Run it

```sh
./check.sh                 # static gate (bash -n, POSIX parse, shellcheck) + full scenario matrix
./run-all.sh               # just the scenario matrix
./run-all.sh w-ts-happy    # one scenario by name
./wizard-sim.sh scenarios/w-ts-happy.scn --keep   # keep the sandbox for inspection
```

Failed scenarios keep their sandbox under `/tmp/lodor-wizsim.<name>.*` — look at `stdout.log`,
`sim/trace.log` (every stub call), and `sdcard/` (the fake SD card).

## How stubbing works

* A throwaway **fake SD card** is built per scenario; the real pak scripts are copied to
  `sdcard/Tools/tg5040/Lodor.pak/` and stubs are placed at the exact `$PAKDIR`-relative paths the
  script resolves (`bin/tg5040/minui-*`, `bin/tg5040/lodor-qr`, `lodor-sync`, `bin/romm-run`,
  `bin/romm-syncd`, `bin/tailscale/*`). No PATH tricks needed for those.
* `sleep` and `killall` are PATH-shadowed (`stubs/`): time is compressed 20×, process reaping is a
  no-op recorder. A genuinely unbounded loop still spins until `timeout` kills the scenario —
  reported as `TIMEOUT — possible interaction loop`.
* `launch.sh` has ONE test hook (`LODOR_TEST_LIB`, inert unless set): `testlib.sh` overrides the
  hardware-facing helpers only (wlan0 probes, tailscale daemon control, resolv/clock writers).
  The wizard, menu dispatch, kb/pick plumbing, `tailscale_mark_tier1`, `ts_reset`,
  `creds_present` etc. all run REAL.
* Stubs read scripted behavior from per-channel queues (`stubs/simq`): **FIFO with a sticky last
  line** — repeated redraws/polls keep receiving the final answer. The `lodor-qr` stub's mode `0`
  is *faithful*: it polls `--statefile` for the `--ready` token like the real SDL helper, which is
  how the sim caught the statefile/statedir collision.
* The `lodor-sync` stub models the engine's config contract: `--set-server` writes `root_uri`,
  a `paired=1` result adds `token`, `registered=1` adds `device_name` — so `creds_present` and the
  entry dispatch behave exactly as on-device.

Scenario directives are documented in the header of `wizard-sim.sh`.

## Bugs this harness caught on day one (2026-07-02, all fixed in launch.sh)

1. `TS_STATE_FILE=/tmp/lodor-ts-state` collided with tailscale-lib's `TS_STATEDIR` (a directory):
   `: > $TS_STATE_FILE` is a redirection failure on a POSIX *special* builtin, which EXITS the
   whole script — every Tailscale QR onboarding died instantly.
2. `case "$PICK_VAL" in http*)` also matches the "https (secure, recommended)" label — every
   onboarding silently wrote `http://` and the TLS question was unreachable.
3. B/menu on the optional-port keyboard wiped a previously-typed port instead of keeping it.

## Wiring

`check.sh` is the single entry point; `assemble.sh` carries a commented gate line to enable it
in the stage path. shellcheck comes from a local binary or the `koalaman/shellcheck:stable`
docker image (with a bind-mount visibility probe so a remote docker daemon skips instead of
linting the wrong filesystem).
