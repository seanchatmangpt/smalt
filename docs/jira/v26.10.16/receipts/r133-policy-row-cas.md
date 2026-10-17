# Receipt — R133 (serialized policy-row CAS for blob container policy)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/data_plane/blob_storage.ex:809`/`:1452` (`cas_policy_row/2` +
  `cas_policy_row_loop/3`): `set_legal_hold` and `set_container_metadata` were
  unlocked read-modify-writes on the shared `:smalt_blob_policy` row — a
  metadata PUT between a hold-set's read and write silently cleared the
  committed hold (W5-8 measured 2884/6400 lost holds). Both writers now
  serialize through `Store.compare_and_swap` / `insert_new` with bounded retry
  and fail-closed 500.
- `lib/smalt/data_plane/blob_service.ex:167` (metadata PUT rides the CAS;
  WORM check runs inside the CAS update fn so a hold committed mid-flight is
  seen on retry → typed 409 ContainerLocked).

## Verification (2026-10-16, W6 docs lane, unedited output)

Dedicated court `test/data_plane/r133_policy_cas_test.exs`, canonical build
root (`_build`):

```
$ mix test test/data_plane/r133_policy_cas_test.exs        # run 1
3 tests, 0 failures
$ mix test test/data_plane/r133_policy_cas_test.exs        # run 2
3 tests, 0 failures
$ mix test test/data_plane/r133_policy_cas_test.exs        # run 3
3 tests, 0 failures
```

Serial CAS gate + happy-path non-vacuity tests (2nd/3rd tests of the court)
also pass inside the 140-test batch
(`telemetry + cosmos + r133_policy_cas`: "140 tests, 1 failure" — the single
failure is the concurrency probe below).

## Open defect (why PARTIAL_ALIVE)

The 32-racer × 200-round concurrency probe is build-root sensitive:

- `_build` (canonical): PASS 3/0, stable across 3 consecutive runs.
- `_build-w6docs` (fresh lane build root): FAILS deterministically, 4/4 runs —
  "policy row missing at end of round" at
  `test/data_plane/r133_policy_cas_test.exs:88` (`Store.get` → `:error` after
  all 32 racers returned 200/409). Debug output showed all 16 hold-sets
  `{:ok, 200, ...}` yet no row present.

Row-missing (not hold-lost) plus build-root dependence points at
environment/interleaving sensitivity (e.g. a racer's `insert_new` racing the
fresh-boot table create), not a lost-update in the CAS itself — no
HOLD_LOST assertion ever fired in any run. Owner: blob data-plane lane; the
fence is real on the canonical build, the probe needs a determinism fix or a
boot-synchronization step before it can gate.

## Resolution (2026-10-16, W8 milestone-doc lane — receipt correction from investigation lane)

The PARTIAL_ALIVE claim above is stale: it was taken against a mid-edit
working-tree state, not the landed tree. The literal string "policy row
missing" does not exist in `lib/` or `test/` under the landed code. An
investigation lane re-ran the same 32-racer probe on the final tree:

- fresh lane build root, run 1: green (0 failures)
- fresh lane build root, run 2: green (0 failures) — deterministic, not flaky
- warm lane build root: green (0 failures)
- canonical `_build`: green (0 failures)

All 4 runs 4/0. Supporting evidence: the D78 end-to-end commit-law audit
(HOLDS) covers the same CAS surface and found no defect. The original finding
text above is retained unedited as the record of the mid-edit observation;
standing corrected PARTIAL_ALIVE → PASS.
