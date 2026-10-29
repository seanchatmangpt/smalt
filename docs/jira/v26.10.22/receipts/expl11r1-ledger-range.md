# EXPL11-R1 — ConfidentialLedger range validation (EXPL-11 F1 repair)

- **Date**: 2026-10-22
- **Lane**: EXPL11-R1, repo /Users/sac/smalt (canonical checkout; MIX_BUILD_ROOT=_build-expl11r1)
- **Standing**: ALIVE
- **Context**: solo
- **Fixes**: EXPL-11 F1 (docs/jira/v26.10.22/receipts/expl11-telemetry-planes-errc.md)

## Fix

EXPL-11 F1 root cause: `seq_of/1` in
`lib/smalt/confidential_ledger/service.ex` silently coerced dot-less
transactionIds to seq 0 (rangeBegin=zzz → range widened to ALL transactions,
200) and crashed the ledger GenServer on dotful non-numeric values
(rangeEnd=notanumber.9 → ArgumentError in handle_call → 500, loopable
unauthenticated DoS).

Two-side fix:

1. `Smalt.ConfidentialLedger.Service.valid_range/2` + `valid_tx_id?/1`
   (pure, public): rangeBegin/rangeEnd must be `N.M` with digit-only `N`/`M`;
   anything else is a typed `{:error, :invalid_range}`. `transactions/3`
   refuses before the GenServer call; the router calls the same pure
   validator BEFORE the service call, so a malformed range never reaches
   `handle_call`.
2. `Smalt.ConfidentialLedger.Router`: `GET /app/transactions` validates the
   range at the boundary → `400 {"error":{"code":"InvalidRange"}}`
   (matches real Azure ACL, which validates transactionId ranges).

Valid range semantics unchanged: valid `N.M` values filter exactly as before;
`nil`/absent sides stay unbounded; pagination and integrity refusal arms
untouched.

## Court (test/internal/expl11r1_ledger_range_court_test.exs, real HTTP)

Real Bandit + real JournalSink on real disk + real curl wire calls, no mocks.
All five legs green (5 passed, 0 failed):

```
$ MIX_BUILD_ROOT=_build-expl11r1 mix test test/internal/expl11r1_ledger_range_court_test.exs
Result: 5 passed
```

Falsifiers, both flipped end-to-end over the wire:

- `GET /app/transactions?rangeBegin=zzz` → **400 InvalidRange** (was 200 with
  ALL transactions)
- `GET /app/transactions?rangeEnd=notanumber.9` → **400 InvalidRange**, ledger
  GenServer alive and answering after (was 500 + GenServer crash / DoS)
- Malformed variants all 400: `"7"`, `"7.x"`, `"x.1"`, `"7."`, `".1"`,
  `"-1.1"`, `"notanumber.9"`, `"%20"` — both rangeBegin and rangeEnd
- Valid ranges unchanged: bounded range returns exactly [id2, id3]; no-range
  returns all 4; half-open rangeBegin returns the tail pair

Service-level parity: `Service.transactions("zzz", nil)` →
`{:error, :invalid_range}`; `Service.valid_range("2.1", nil)` → `:ok`;
`valid_range("7", nil)` → `{:error, :invalid_range}`.

## Regression

ACL/ledger suites green on the same build:

```
$ MIX_BUILD_ROOT=_build-expl11r1 mix test test/integration/az3_confidential_ledger_court_test.exs test/integration/az3b_ledger_mount_court_test.exs
Result: 8 passed
```

## Concurrency disclosure

Mid-lane, `lib/smalt/confidential_ledger/service.ex` received an in-flight
concurrent edit (certify_segment/seg_meta hardening, BK-SEAL2 lane) that
transiently broke compile (TokenMissingError, missing `end`). Per the
compile-freeze SLA I waited; the owner completed it and the tree compiled
(warnings only) before my court legs ran. My diff to that file is limited to
the `transactions/3` spec + `valid_range/valid_tx_id?/digits?` block; the
certify_segment/seg_meta region is the other lane's, and both suites above
pass on the merged file.

## Note on scope

My probe also surfaced that JournalSink seq numbering under the merged
substrate may differ from the historical 1-based ids (probe showed 0.1-based
ids in an isolated --no-start boot); the az3/az3b courts pass on the merged
tree, so I did not chase it further — recorded here as an observation only.
