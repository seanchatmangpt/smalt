# i21-leak-court-delta — post-batch leak-court delta (baseline 122 → 101)

Standing: PARTIAL_ALIVE
Context: full (static leak-court scan over test/)

## Context

Three remediation lanes landed batch receipts first (verified on disk before
the court ran):

- `docs/jira/v26.10.17/receipts/i21-leak-batch1.md` (auth_enforce, ets identity tests)
- `docs/jira/v26.10.17/receipts/i21-leak-batch2.md`
- `docs/jira/v26.10.17/receipts/i21-leak-batch3.md`

## Command + real output

```
$ just leak-court
== test-isolation-leak court ==
scanned 153 .exs files under test/ (1 allowlisted)
...
-- OFFENDERS (47 files, 101 mutations uncovered) --
...
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=47 fixtures_refused=True receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
error: recipe `leak-court` failed on line 9 with exit code 1
```

Gate exit=1 (expected: gate exits 1 while findings remain; see
`justfile.d/25-leak-court.just` header — not wired into `just court` until
remediated).

## Delta

- Baseline (i20e): 122 uncovered mutations.
- Now: **101 uncovered mutations across 47 files** (full output captured at
  `/tmp/leak-court-i21.out`; machine receipt at
  `tmp/invariant-gates/test-isolation-leak-receipt.json`).
- **Delta: −21 (−17.2%)** from the three i21 batches.

## Remaining top offenders

By file (mutation count):

| count | file |
|---|---|
| 5 | test/e2e/s6_checkpoints/checkpoint_chain.exs |
| 4 | test/wire/arm_wire_test.exs |
| 4 | test/compliance/c5_servicebus.exs |
| 4 | test/amqp/flow_credit_test.exs |
| 3 | test/wire/egress_wire_test.exs |
| 3 | test/eventgrid_topics_arm_test.exs |
| 3 | test/eventgrid_conformance_test.exs |
| 3 | test/data_plane/audit_planes_test.exs |
| 3 | test/compliance/c7_events.exs |
| 3 | test/compliance/c3_cosmos.exs |

By mutation key (env key mutated without save-restore):

| count | key |
|---|---|
| 9 | `smalt.:arm_port` |
| 8 | `smalt.:egress_port` |
| 8 | `smalt.:amqp_port` |
| 7 | `smalt.:sb_shared_key` |
| 6 | `smalt.:lro_delay_ms` |
| 4 | `smalt.:event_hubs_port` |
| 3 | `smalt.:maa_measurement_baseline` |

## Note

`fixtures_refused=True` — negative fixtures still refuse (anti-vacuity intact
after the batch edits).

Standing rationale: PARTIAL_ALIVE — court still exits 1 on 101 findings; the
−21 delta is observed, remediation incomplete.
