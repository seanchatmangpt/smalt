# Receipt: i29-stress-residual-classify

Date: 2026-10-18 (runs 22:42–22:46 PDT)
Context: slice(solo ×3 each)
Standing: PASS (both faces classified LOAD-FLAKE, no `lib/` fix required)
Ledger: F60 + F61 appended to `docs/jira/v26.10.17/FLAKE_LEDGER.md`

## Subject

Two stress-tier faces from `receipts/i29-stress-fresh2.md`, classified by the
solo-bisect-first protocol (solo ×3 each, `scripts/fast_test.sh`, per-hash
private build roots).

## Face 1 — F60: egress CVM attestation release 503 (test/wire/egress_wire_test.exs:150)

Solo ×3 via `scripts/fast_test.sh test/wire/egress_wire_test.exs:150`
(build root `_build-ft-b0d3a2bc`):

```
run 1: 1 test, 0 failures (21 excluded)   wall: 281s (cold root, 155 files)
run 2: 1 test, 0 failures (21 excluded)   wall: 17s
run 3: 1 test, 0 failures (21 excluded)   wall: 14s
```

All green. Mechanism: same shape as F58 — the egress data-plane answered 503
under concurrent stress-tier fleet load before its release route was ready;
solo the readiness window closes before the first request. LOAD-FLAKE.

## Face 2 — F61: topology ResourceWriteSuccess resourceUri mismatch (test/azsim/topology_test.exs:141)

Solo ×3 via `scripts/fast_test.sh test/azsim/topology_test.exs:141`
(build root `_build-ft-be19d7a1`):

```
run 1: 1 test, 0 failures (7 excluded)    wall: 136s (cold root)
run 2: 1 test, 0 failures (7 excluded)    wall: 1s
run 3: 1 test, 0 failures (7 excluded)    wall: 1s
```

All green. Premise read: the test PUTs a **Storage account** and asserts the
fan-out event's `data.resourceUri` is the storage-account URI; the emission in
`lib/` carries the PUT's own resourceUri, so the expectation is correct and the
emission is correct — the stress-run failure was the Event Grid subscription
fan-out delivering a *concurrent* test's Service Bus namespace event to this
subscriber under load. LOAD-FLAKE (shared-subscriber event race), not an
expectation or emission defect.

## Verbatim bench-machine

```json
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Notes

- Two pre-existing compiler warnings observed in the topology build
  (`variable "lock" is unused`; `default values for the optional arguments in
  the private function mint_local/2 are never used`) — pre-existing, not
  session-introduced, not touched by this lane.
- No git actions performed (per task).
