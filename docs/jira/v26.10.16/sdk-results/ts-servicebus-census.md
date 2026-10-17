# SDK lane TS-08 — Service Bus census (real @azure/service-bus) against the smalt substrate

- **Date**: 2026-10-16 · **Lane**: lane333 census lane (v26.10.16)
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea` (uncommitted lane diffs in `lib/` owned by other lanes; no lib/ edits by this lane)
- **SDK**: `@azure/service-bus` (from `test/sdk-smoke/node_modules`)
- **Runtime**: Node (workspace), macOS arm64 (Darwin 25.2.0)
- **Substrate**: `MIX_ENV=test` `mix run --no-halt` self-boot via `test/sdk-smoke/census-run.mjs`, anonymous auth, private ports AMQP 39798 / ARM 39796 (EGRESS 39797 / EH 39799 also pinned), `MIX_BUILD_ROOT=_build-lane333`, entire window under exclusive `flock /tmp/smalt-substrate.lock` (lock fd closed on the beam)
- **Harness**: `SMALT_SDK_ROOT=test/sdk-smoke/node_modules bash scripts/sb_census_replay.sh`
- **Verdict**: census 11/11 probes PASS — exit 0, fail-closed, zero skips

## executed commands (receipt)

```bash
MIX_BUILD_ROOT=_build-lane333 \
SMALT_TEST_ARM_PORT=39796 SMALT_TEST_EGRESS_PORT=39797 SMALT_TEST_AMQP_PORT=39798 SMALT_TEST_EVENT_HUBS_PORT=39799 \
SMALT_SDK_ROOT=test/sdk-smoke/node_modules bash scripts/sb_census_replay.sh   # exit 0
```

(First invocation exited 2: the fresh `_build-lane333` root's cold compile
overran the 60 s boot-poll window; pre-compiled the lane build root, reran
clean. This is KD-48's harness class, witnessed again.)

## final results (2026-10-16, exit 0)

```
▶ service bus census: 11 probes, fail-closed, zero skips
  ✔ probe: authentication (27.3ms)
  ✔ probe: bytes (417.2ms)
  ✔ probe: exclusive-session (78.1ms)
  ✔ probe: renewal-peek (43.6ms)
  ✔ probe: abandon-complete (10.1ms)
  ✔ probe: stale-handle (15183.7ms — PT15S queue, real lock expiry)
  ✔ probe: dead-letter (8.7ms)
  ✔ probe: dlq-properties (9.1ms)
  ✔ probe: ordered-session (8.3ms)
  ✔ probe: lock-duration (2160.1ms — PT2S queue, real lock expiry)
  ✔ probe: deferred-receive (8.2ms)
✔ service bus census: 11 probes, fail-closed, zero skips (17963ms)
ℹ tests 12  pass 12  fail 0  cancelled 0  skipped 0
CENSUS_EXIT=0
```

## supplementary probe (sb-extra.probe.cjs, TS-4) — run against a lane333 private substrate

Same lock discipline, persistent substrate amqp=39798/arm=39796, shared key
injected. Result 2/3: `receiveAndDelete-delivery` PASS,
`acceptNextSession-no-session` PASS,
`scheduleMessage` → `NotImplementedError: UNSUPPORTED_OPERATION` — the
`$management` scheduling operation (registered OPEN divergence KD-47, evidence
this surface). Supplementary detail lives in this window's
`receipts/08-servicebus-census.md`.

## notes

- No lib/ edits by this lane; substrate/census harness untouched.
- KD-48 re-witnessed (cold lane build root vs 60 s poll window) — front door
  now exports SMALT_TEST_*_PORT defaults, so the private-port path is the
  supported invocation.
