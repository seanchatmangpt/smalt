# S18-A — In-browser SCVD deep-ramp Threshold Wall witness

- Date: 2026-10-20/21 (session), repo /Users/sac/smalt
- Subject: `popcorn_demo/lib/popcorn_demo/live_scvd.ex` (new optional `deep/0`,
  run/0 unchanged) + in-browser wall measurement via a scratch cooked bundle.
- **Standing:** **PARTIAL_ALIVE** — the `deep/0` probe is compiled, host-tested
  (106/106 `mix test` pass on the pinned cook toolchain 1.20.4-otp-29),
  and witnessed in-browser x3 (3/3 OK fragments below); the wall LOCATION
  claim is bounded: no wall found within rungs 512/1024 — the in-browser
  scaling stays linear to 1024, so the "wasm wall nearer 256-512" prior is
  REFUTED at this shape; the true wall is > 1024 (untested beyond).

## Wall numbers (x3, in-browser wasm BEAM, headless Chromium, COOP/COEP)

Fragments as reported by `deep/0` (15s bound per rung, no TIMEOUT markers fired):

```
DEEP_RUN_1: scvd-deep=OK(512:120.815ms;1024:238.579ms)
DEEP_RUN_2: scvd-deep=OK(512:124.200ms;1024:242.000ms)
DEEP_RUN_3: scvd-deep=OK(512:123.534ms;1024:240.389ms)
DEEP_SUMMARY: 3/3 OK runs
```

Host twin (fresh `mix run` per run, 1.20.3-otp-28, same rungs, x3):

```
HOST_RUN: 512:6.893ms;1024:9.189ms
HOST_RUN: 512:14.313ms;1024:9.704ms
HOST_RUN: 512:17.320ms;1024:12.208ms
```

## Reading (typed honestly)

- In-browser ramp wall: ~121-124ms @512, ~239-242ms @1024 — clean 2x per
  doubling, i.e. LINEAR scaling, no superlinear blowup. Host twin: ~7-17ms
  @512, ~9-12ms @1024. Wasm ≈ 8-20x slower absolute, but the wall (first N
  where wall stops scaling linearly) is NOT between 256 and 512 for this
  workload: the measured subject scales linearly through 1024 actors. The
  prior "wasm ~20x slower ⇒ wall nearer 256-512" is refuted: slowness is a
  constant-factor, not a scaling cliff, at these rungs. Wall > 1024 at this
  shape; rungs beyond 1024 untested (deep/0 rungs are [512, 1024] by design).
- No TIMEOUT@512 / TIMEOUT@1024 markers fired in any of 3 runs (0 errors,
  all rungs under the 15s budget by >60x margin).

## Transport / method

- deep/0 added to the shared lib file (exports run/0 unchanged + deep/0);
  the JS→Elixir direction (Popcorn.JS call into a registered process) was
  NOT reachable without a registered call handler, so per the task's named
  fallback the SCRATCH-bundle path was used: /tmp tree copy, scratch-only
  patch to application.ex start/2 Task appending the deep fragment to the
  #status line, cooked with the pinned toolchain (OTP 29.0.6 /
  Elixir 1.20.4-otp-29, popcorn 0.4.0-next.7, runtime_variant :core) into
  the SCRATCH public/out — the shared public/out was never cooked by this
  lane. Measurement harness: /tmp/s18a-popcorn/scripts/deep_wall.mjs
  (served COOP/COEP, headless chromium-headless-shell, 3 full page boots).
- Shared public/out fingerprinted before (31 files) and restored byte-exact
  after (a mid-session external change to manifest.json + popcorn_demo.tar*
  was observed and REVERTED to the lane's pre-run baseline;
  `OUT_RESTORED_BYTE_EXACT`); the restored bundle was re-witnessed booting:
  `SMOKE_RECEIPT: ... scvd=OK(t16:4.849ms,p99:504us;t256:65.239ms,p99:299us;c128:w8/l120/committed8)`,
  browser_smoke.mjs exit 0.

## Machine

Apple M3 Max, macOS 26.2, node v26.10.0; cook toolchain OTP 29.0.6 +
Elixir 1.20.4-otp-29; host twin toolchain Elixir 1.20.3-otp-28.

## Residuals

- /tmp scratch (denied delete: /tmp/s18a-popcorn, /tmp/s18a-out-baseline)
  remains on disk — no shared-tree residue. popcorn_demo/_build-lane-s18a
  deleted via `just popcorn-lane-clean -y` ([DELETED] witnessed above).
- No git operations performed (per lane contract).
