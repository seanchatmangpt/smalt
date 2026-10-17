# Receipt — R144 (lock ABA CAS + telemetry read guard)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

Session-listed as "lock ABA CAS + telemetry read guard, 33/0 ×3". The lock-ABA
CAS surface is `lib/smalt/messaging/amqp/lock_manager.ex` (lock acquisition under
an ABA-prone token reuse); the telemetry read guard is the read-path hardening in
`lib/smalt/telemetry.ex` (same family as R157's prune guard).

No R144 literal marker exists on disk (grepped `lib test scripts gates docs` —
zero hits outside receipts); receipt written from the session-verified subject
list plus suite-level verification.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/amqp/lock_manager_test.exs
19 tests, 0 failures
$ MIX_BUILD_ROOT=_build-w7docs mix test test/telemetry_test.exs
14 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/amqp/lock_manager_test.exs
19 tests, 0 failures
$ MIX_BUILD_ROOT=_build-lane204 mix test test/telemetry_test.exs
14 tests, 0 failures
$ MIX_BUILD_ROOT=_build-lane204 mix test test/amqp/fuzz_test.exs   # F3 leg, run 1 of 3
34 tests, 0 failures
$ ... run 2 of 3: 34 tests, 0 failures
$ ... run 3 of 3: 34 tests, 0 failures
```

Combined lock_manager+telemetry = 33/0 (matches the session-cited 33/0). The
F3 fuzz fence held across 3 consecutive runs (34/0 each, exit 0 each).
Standing: PASS.
