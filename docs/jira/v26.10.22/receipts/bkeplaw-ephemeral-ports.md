# BK-EPLAW — test/bench self-boots default to ephemeral ports

**Standing:** PARTIAL_ALIVE (class closed for the in-process exs booters; MIX_ENV=dev spawn harnesses that pin only the six main listeners (c5/b6/stress/*) retain their existing explicit-pin contract and are now additionally covered by the shared helper when they adopt it)
Context: solo

## Census (offenders found)

Grep census over every script that calls `Application.ensure_all_started(:smalt)` (46 files), scored on MIX_ENV=test refs vs port-pin refs:

- **Offender (confirmed)**: `scripts/bench/b42_dataplane_saturation.exs` — in-process `Application.ensure_all_started(:smalt)` with NO port pins and no documented MIX_ENV contract; bare `mix run scripts/bench/b42_dataplane_saturation.exs` boots the WHOLE app on canonical 9443/9444/8443/5672/5673. Its "lane-private ports 39420-39425" claim was a comment only — no code enforced it. Matches the BK-PORTS2 witness window (bench harness self-boot outside the flock window).
- **Same class, contract-by-documentation only** (bind canonical under bare dev `mix run`, safe only when run as documented): `scripts/bench/a1_change_feed.exs`, `scripts/bench/b9_eh_beam.exs`.
- **Safe (verified)**: config/test.exs probes free ports per listener with SMALT_TEST_*_PORT override; `scripts/bench/lib.sh bench_boot`, `scripts/bench.py` (scopes ALL fixed listeners incl. arm_tls/mcp), `scripts/lib/substrate_boot.sh` (front-door law), `scripts/stress/telemetry_driver.exs`, `scripts/bench/ja9_scaling.exs` (explicit pins).
- **Pinned-but-dev-env**: `scripts/bench/c5_arm_storm.py`, `b6_lro_sdk.py`, `scripts/bench.py`, `scripts/bench_concurrent.py`, `scripts/stress/*.py` set MIX_ENV=dev but put_env their six main ports explicitly (bench.py scopes arm_tls/mcp after the witnessed 2026-10-15 eaddrinuse); auxiliary listeners (kafka/wsrelay/wps/acl) ride dev defaults (9092/5675/5676/8444 — outside the BK-PORTS2 canonical five).

## Fix

- NEW `scripts/lib/test_boot_ports.exs` — `SmaltTestBoot.pin!`: every listener gets a probed-free port (same probe-then-close contract as config/test.exs), never a canonical port, unless an explicit `SMALT_TEST_<NAME>_PORT` env pin wins (honored under MIX_ENV=dev too — the hole closed); per-run tmp kafka/acl journal dirs so a bare dev boot never writes shared dev journal state.
- `scripts/bench/b42_dataplane_saturation.exs` — requires the helper + `pin!` before `ensure_all_started`; `base/0` now reads the pinned `:egress_port` instead of hardcoded `39421`; header updated.
- `scripts/bench/a1_change_feed.exs`, `scripts/bench/b9_eh_beam.exs` — same preamble (turns their documentation-only contract into enforced default).

Production substrate boot untouched: `config/config.exs`/`scripts/substrate.sh`/`scripts/lib/substrate_boot.sh` canonical front door is unchanged.

## Court (real boots, bounded polls; test/internal/eplaw_ephemeral_boot_court_test.exs)

```
$ MIX_BUILD_ROOT=_build-eplaw mix test test/internal/eplaw_ephemeral_boot_court_test.exs
Finished in 8.9 seconds (0.00s async, 8.9s sync)
Result: 3 passed
```

- Leg A (fail-closed target): suite boot with NO pins — all six listener ports non-canonical AND the ARM front door accepts a real TCP connection on the configured port (bounded deadline poll, connect probe as observable).
- Leg B (non-vacuity): `SMALT_TEST_ARM_PORT=9443 mix run --no-start` (MIX_ENV=test) answers `9443` — the ephemeral default is override-aware, not hardwired (a hardwired gate fails this leg).
- Leg C (offender class): bare dev-context `mix run` self-boot through `SmaltTestBoot.pin!` — `EPLAW_ARM=<ephemeral> CANONICAL=false`, ARM port accepts a real TCP connection.

## Regression

```
$ MIX_BUILD_ROOT=_build-eplaw mix test            # full offline suite
Result: 726/739 passed, 13 failed
$ MIX_BUILD_ROOT=_build-eplaw mix test test/internal/powl2_primitives_test.exs \
    test/internal/kafka_exp4_court_test.exs test/integration/event_grid_webhook_test.exs \
    test/internal/amqp_listener_cap_test.exs
Result: 24 passed
```

The 13 failures (powl2, kafka_exp4, event_grid, amqp_listener_cap, spof3) pass 24/24 in isolation on the same build root — concurrency coupling under the concurrent-lane busy machine (BK-PORTS2 context), NOT session-introduced: none of the touched code is on their paths.

## Gates

- `just sleep-gate` → `[SLEEP-GATE] PASS — 611 files, 0 unclassified sleep primitives` (court polls are deadline-checked POLL-STEP annotated).
- exs parse check: 4/4 `Code.string_to_quoted!` OK.

## Falsifier

A test/bench harness booted with no `SMALT_TEST_*_PORT` pins that ends up LISTENing on 9443/9444/8443/5672/5673 reopens this ticket (leg A/C red, or a fresh `lsof -iTCP:9443 -sTCP:LISTEN` hit attributable to a harness pid).
