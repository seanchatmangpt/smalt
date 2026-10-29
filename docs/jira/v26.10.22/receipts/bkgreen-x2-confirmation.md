# BK-GREEN — post-wave full-ladder confirmation (×2)

**Standing:** PARTIAL_ALIVE — every stage green except `mix test`, which carries 5 deterministic reds (4 census + 1 ets_auto; real, typed, correctly-refusing) plus load-bound flakes that pass in isolation. This is NOT the seal's full-green ×2 yet; the one open hop is census/registry re-registration of the 4 newly-landed `test/internal` files.
**Context:** solo
**Date:** 2026-10-22
**Lane:** BK-GREEN, `MIX_BUILD_ROOT=_build-bkgreen`

## Stage results (real exit codes)

| # | Stage | Exit | Result |
|---|---|---|---|
| 1 | `mix compile --force` | 0 | compiles clean; 8 top-level `warning:` diagnostics (incl. deps/plug type-shadow class, e.g. `Smalt.Mcp.Router.invoke/2` shadowing) |
| 2 | `mix test` (full offline) | 2 | run 2 (full-log): **764/780 passed, 16 failed** (run 1: 758/780, 22 failed — failure set differs run-to-run; classification below) |
| 3 | `just invariant-gates` | 0 | **6/6 PASS** (positive held + all negative fixtures refused; receipts `tmp/invariant-gates/*.json`) |
| 4 | `just sleep-gate` / `just sleep-gate-court` | 0 / 0 | 616 files, 0 unclassified sleep primitives; non-vacuity court PASS (restore byte-exact, 11 subjects) |
| 5 | `just docs-dod-check` | 0 | all cited doc/receipt paths OK; folded kd-receipt-fence: 311 cites OK |
| 6 | `scripts/receipt_index.py` | 0 | receipts=1373 sdk=61 total=1434 suspects=38 (pre-existing standing/NO-CONTEXT class; exit 0) |
| 6 | `scripts/kd_flip.py` (read-only) | 0 | 120 KD ids / 143 files; FLIP-ELIGIBLE 0; FLIP-PENDING-WITNESS 2 (KD-168 mention-only refused; KD-175 no post-shim receipt newer than 2026-10-22T05:13:34); WITNESS-AMBIGUOUS 1 (KD-174: 3 candidate receipts, needs `--witness KD-174=<path>`) |
| 6 | `scripts/kd_receipt_fence.py` | 0 | 311 receipt cites across 6 registers OK |
| 7 | `node scripts/e2e-court.mjs` | 0 (run 5) | **73 PASS / 0 FAIL / 3 typed SKIP** |
| 7 | 6 node courts (pattern, hooks, codec, snapback, tab-lease, dom-contract) | 0 ×6 | all green (13 PASS/3 SKIP/0 FAIL; all-green; PASS 0-fail; all-pass; 7/0; PASS 0-fail) |

## mix test classification (typed, no fixes applied)

**REAL, deterministic (also fail in isolation):**
- `test/internal/internal_tier_census_test.exs` — 4 tests, census population fence + surface gates. Verbatim (log line 756):
  `test/internal population drifted: on_disk=MapSet.new(["expl9r1_egress_guard_court_test.exs", "expl9r2_arm_guard_court_test.exs", "kd169r_cred_gate_test.exs", "mcpt1_dispatch_court_test.exs"]) unregistered=MapSet.new([])` (log line 756) — the census registry has not absorbed the 4 repair-wave test files. **Fix = census registry re-registration; owner = census/register lane.**
- `test/internal/ets_auto_court_test.exs:147` — "64-task concurrent increment court": `:ets.update_counter(:smalt_rolling_counters, ...)` → `ArgumentError ... table identifier does not refer to an existing ETS table` (test/internal/ets_auto_court_test.exs:172). Fails in isolation on an otherwise quiet path → REAL: named-ETS lifetime/boot coupling in the court's task fan-out; **owner = ets_auto court lane (EXPL/INTERNAL)**.

**FLAKE (pass in isolation, fail only under full-suite load/ordering — FLAKE_LEDGER F8 class, shared named-ETS lifetime coupling):**
- `test/integration/amqp_kd131_133_triage_test.exs` — 22 (run 1), passes fully in isolation (7/7).
- `test/internal/powl2_primitives_test.exs` — 6 (run 2), pass in isolation.
- `test/internal/kafka_wire_test.exs` — 1 (run 2), passes in isolation.
- `test/data_plane/kql_sealed_court_test.exs` — 1 (run 2), passes in isolation.
- `test/internal/spof3_affidavit_engine_court_test.exs` — 1 (run 2), passes in isolation.
- ets_auto "ON leg" test — failed run 2 full, passed in isolation → flake edge of the same class.

## Stage 7 run-1..4 reds (lane collision + in-flight owner repair, not product defects)

- Runs 1–2: kd173c `next dev :39751` leg — `EADDRINUSE` from the concurrent sibling lane's court on the fixed port; waited for drain, did not kill the sibling's process.
- Run 3: crashed at the then-stale `a.kill()` call in `e2e-court.mjs:517`; the file changed under the run — the KD-173C owner landed the `killA`/`killB` contract fix mid-flight (verified: harness `SAME as HEAD`, e2e-court.mjs `DIFFERS from HEAD` with the new contract). My run-3 crash orphaned its own `next dev` (next dev's per-project lock then blocked leg (b)); I killed **my own orphan only** and re-ran.
- Run 5: full green (73/0/3 typed SKIP: DOM panel rendering, popcorn iframe src needs :3100 server).

## Notes

- No `bks2*` receipt appeared on disk during my window; I ran as the independent full-ladder confirmation regardless.
- `receipt_index.py` rewrote the 16 `RECEIPTS.md`/`INDEX.md` projections (standard regeneration; byte-drift, if any, belongs to the receipt-index projection, not this lane's diff).
- Falsifier for the seal: a rerun after census registration + ets_auto court repair returning `mix test` exit 0 upgrades this receipt to the seal's ×2 ALIVE.
- Build root `_build-bkgreen` left in place (lane lease; coordinator cleans at integration).