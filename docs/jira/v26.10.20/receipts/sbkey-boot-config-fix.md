# Receipt: SBKEY boot-config fix (M4 — 12-byte :sb_shared_key defect)

- **Lane**: SBKEY (writer), repo /Users/sac/smalt, build root `_build-sbkey`
- **Standing**: PARTIAL_ALIVE — fix landed and verified; kd134 flake (pre-existing,
  load-sensitive) disclosed below; not committed (coordinator owns git).
- **Date**: 2026-10-21

## Defect (M4 witness)

A shared-substrate boot without an explicit `:sb_shared_key` left CBS SAS signing
impossible against a dev boot: SasVerifier's 32-byte floor
(`lib/smalt/messaging/amqp/sas_verifier.ex` `@min_key_bytes 32`) could not be met by
the 12-byte historical key ("ws8sharedkey" shape), so real clients got
`401 INVALID_LOCAL_SAS` and smalt-migrate verify had to loud-skip the servicebus leg.

## Diff (66 lines, 3 files)

1. `lib/smalt/messaging/amqp/sas_verifier.ex`
   - `generate_dev_key/0`: was `Base.encode64(strong_rand_bytes(48))` (per-boot random,
     so dev clients could never derive it); now the deterministic dev_env derivation
     `Base.encode64(sha256(hostname <> "smalt-dev-sb"))` — byte-identical to
     `scripts/dev_env.sh:31` and `scripts/substrate.sh:209`, 44 chars, >= 32-byte floor.
   - New `validate_boot_key!/0`: a configured `:sb_shared_key` below the 32-byte floor
     raises `ArgumentError` naming `:sb_shared_key` (typed boot refusal); `nil` and
     >=32B keys pass. `shared_key/0`'s KD-131 runtime fallback is unchanged (sub-floor
     key never reaches the HMAC).
2. `lib/smalt/application.ex`: `start/2` calls `:ok = SasVerifier.validate_boot_key!()`
   before telemetry attach, so a sub-floor configured key refuses boot loudly.
3. `test/integration/sbkey_boot_config_test.exs` (new, 3 tests, Chicago: real
   SasVerifier, real HMAC sign+verify, no mocks):
   - nil config -> `shared_key()` == the dev_env derivation, and a token minted from it
     verifies via the real `SasVerifier.verify/2` (endpoint audience).
   - 12-byte configured key -> `validate_boot_key!/0` raises ArgumentError (~/:sb_shared_key/).
   - KD-131 divergence preserved: sub-floor key never returned by `shared_key/0`.
   - Existing `test/integration/amqp_kd131_133_triage_test.exs` still green (7/7) —
     its "sub-floor falls back (documented divergence)" assertion is unchanged.

## Command output (real)

```
$ MIX_BUILD_ROOT=_build-sbkey scripts/fast_test.sh test/integration/sbkey_boot_config_test.exs
...
Finished in 0.04 seconds (0.00s async, 0.04s sync)
3 tests, 0 failures
$ MIX_BUILD_ROOT=_build-sbkey scripts/fast_test.sh test/integration/amqp_kd131_133_triage_test.exs
...
7 tests, 0 failures
```

## Verification ladder + disclosures

- `test/internal/internal_tier_census_test.exs` shows 3 PRE-EXISTING failures from other
  lanes' untracked files (`scvd_concurrency_courts.exs`, `event_grid_backpressure_test.exs`
  population/allowlist/status-literal drift) — not session-introduced by this lane.
- `test/internal/kd134_requester_delivery_test.exs` is FLAKY under current machine load
  ("re-availed message prefers the requesting receiver", an eventually-poll on transfer
  steal): measured 3 pass / 1 fail at HEAD baseline vs 7 pass / 5 fail with this diff in
  interleaved runs; sign/verify key agreement is invariant under this diff (client and
  server both resolve `shared_key/0` in-VM, so determinism cannot break the HMAC match),
  and the failing assertion is a queue claim/transfer timing poll, not the SAS path.
  Judged pre-existing load-correlated flake, disclosed per the errors-must-be-named law.
- Shared substrate NOT restarted (per task); fix takes effect at next recycle. Note: the
  running substrate pins its key via `scripts/substrate.sh` already deriving >=32B, so a
  recycle is safe; boots that export a short `SMALT_SB_SHARED_KEY` will now refuse.
- Machine: (bench-machine receipt not required — not a bench lane; host: macOS
  Darwin 25.2.0, arm64).

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-sbkey scripts/fast_test.sh test/integration/sbkey_boot_config_test.exs
MIX_BUILD_ROOT=_build-sbkey scripts/fast_test.sh test/integration/amqp_kd131_133_triage_test.exs
```
