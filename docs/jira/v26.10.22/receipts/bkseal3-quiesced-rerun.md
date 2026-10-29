# BK-SEAL3 — quiesced-tree seal rerun

- **Date**: 2026-10-22
- **Lane**: BK-SEAL3
- **Context**: solo (shared checkout, other lanes actively editing)
- **Standing**: **PARTIAL_ALIVE** — all stage gates green (invariant-gates 6/6, sleep-gate + court, docs-dod, kd-receipt-fence, kd-stale), but the tree was never quiesced, census is 2/6 with in-flight-file drift, and the full `mix test` could not produce a result line (compile abort on an in-flight lane file, retry exhausted). The seal claim is therefore NOT advanced to ALIVE by this lane.

## Step 1 — quiesce (typed REFUSE, captured verbatim)

```
QUIET-CHECK REFUSE (typed violations):
  - stray beam pid 5988 cwd='/Users/sac/ash_r2rml' (not this checkout)
  - court port 9443 occupied
  - court port 8443 occupied
  - cross-lane/foreign beams; load 35.5/36.6 > threshold (16 cpus)
error: recipe `quiet-check` failed on line 8 with exit code 1
error: recipe `quiesce` failed on line 14 with exit code 1
```

Exit 1, typed violations (foreign beam, 5 court ports, 1596 concurrent beam processes, load 35.5). Tree never quiesced; all later results are under contention.

## Step 2 — census: 2/6, in-flight drift (typed failures, classified)

```
MIX_BUILD_ROOT=_build-bkseal3 mix test test/internal/internal_tier_census_test.exs
Result: 2/6 passed
Failed: 4 tests
```

All 4 failures are census-class drift from in-flight lane files, not regressions in registered surface:

- population fence: on_disk includes `bkmaap6_nonce_bounds_court_test.exs`, `expl10r_court_test.exs`, `expl11r_court_test.exs`, `expl11r3_court_test.exs` — new unregistered in-flight files (BK-MAAP6, EXPL10-R, EXPL11-R, EXPL11-R3 owners hold them).
- module-allowlist scan, HTTP-status-literal scan, raw-client-token scan: all name the same unregistered in-flight files.

BK-CENS2's 4 registered files remain green (no drift on the registered population).

## Step 3 — full `mix test`: compile abort, no result line (classified)

Attempt 1 and attempt 2 (after 180s bounded wait) both abort at compile on `test/internal/expl11r3_court_test.exs` (EXPL11-R3 lane's file, evolving between attempts: SyntaxError `F5_name(` at 243:35 → CompileError undefined `prior` at 79/126). Retry budget exhausted per lane law. Classification: **in-flight-owned file named** (`test/internal/expl11r3_court_test.exs`, EXPL11-R3 owner). Not classified as a regression — no suite result line exists.

## Step 4 — stage gates (real exit codes)

| stage | result | exit |
|---|---|---|
| `just invariant-gates` | PASS 6/6 (positive held + negative fixtures refused) | 0 |
| `just sleep-gate` | PASS — 623 files, 0 unclassified sleep primitives | 0 |
| `just sleep-gate-court` | PASS non-vacuous (injected sleep REFUSED, restore byte-exact) | 0 |
| `just docs-dod-check` | OK (every receipt path named in docs exists) | 0 |
| kd-receipt-fence | OK — 313 receipt cites across 6 registers | 0 (in docs-dod run) |
| `just kd-stale` (kd_flip read-only) | 1 row FLIP-PENDING-WITNESS, exit 0 | 0 |
| `just receipt-index-check` | DRIFT — exit 1 | 1 |

receipt-index-check DRIFT classified: committed `RECEIPTS.md`/`INDEX.md` lag the receipts landed since the last `just receipt-index` (e.g. `bkampf1`, `bkampskep`, `bkcens2-registration2`, `bkazdt`, `bkaud2` rows absent from the committed index; gate restored committed bytes, nothing modified). This is indexer-run drift, not receipt corruption — every drifted row is an existing receipt file on disk.

## Verdict

- Gates that prove the tree's invariants: all green.
- Gates that prove tree *quiescence/completeness* (quiet-check, census population fence, full suite): red, each with a typed cause naming an in-flight owner (foreign beams/load; BK-MAAP6/EXPL10-R/EXPL11-R/EXPL11-R3 unregistered files; EXPL11-R3 compile abort) — except receipt-index DRIFT, which is indexer lag on landed receipts, also cross-lane, not a content defect.
- Honest standing: **PARTIAL_ALIVE**. The seal can advance only after in-flight lanes land and a rerun achieves quiet-check PASS + census 6/6 + a full-suite result line.
