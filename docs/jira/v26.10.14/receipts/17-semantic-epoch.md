# Receipt — V261014-17 semantic epoch doc-fact reconciliation

- **Lane**: 17 of 20, v26.10.14 fan-out, canonical checkout `/Users/sac/smalt`
- **Scope honored**: docs + comments only; no production code, no git state changes.

## Changes

1. `docs/PACK_INTEGRATION/semantic-epoch.md` (~:43-45): stale drift-row claim
   (`3f7d1f3a…` vs lock `70a135be…`) rewritten to mixed-history facts with the
   recomputed live lock digest `83a3bb18…`; noted pre-re-lock `4fe9d26c…` rows
   are historical, not live drift, fenced by
   `test/smalt_registry_replay_identity_test.exs:56-70`.
2. `docs/TEST_ISOLATION.md` :62 and :78 only: `test/pplan_test.exs` removed
   from the `Store.clear()` in setup inventory (25 → 24); :62 clause updated
   with parenthetical that pplan_test is covered by the spawn-leak-tracer
   section instead. Other sections untouched (targeted Edits).
3. `test/semantic_epoch_test.exs` (~:106): comment extended with one
   dependency note — the `any?(:ok)`/`any?(:digest_drift)` pair assumes both
   lock eras persist in the ledger; a deliberate ledger cleanup must update
   the pin in the same change. Assertions untouched.
4. Re-lock procedure: no action (per work order).

## Digest recomputed at landing time

`python3 -c "...packs['smalt-substrate-pack']['sha256']"` over
`ggen_igniter.pack.lock` →
`83a3bb18af8844aaf2b25639c448eb4e2aba2415319fa1998a95071a4a39177f`
(matches work-order background; not copied from it).

## Verification (real output)

- `mix test test/semantic_epoch_test.exs` → `21 tests, 0 failures`
- `mix test test/smalt_registry_replay_identity_test.exs` → `2 tests, 0 failures`

## Standing

ALIVE — both acceptance gates green on the working tree at landing time.
