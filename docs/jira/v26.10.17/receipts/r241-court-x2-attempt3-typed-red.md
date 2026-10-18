# r241 — court-x2 attempt 3 (final): TYPED-RED, pre-mortem mitigation did not hold

Standing: TYPED-RED (honest; WO-2 attempt 3 of 3, closes per r240 fallback)
Context: full (two fresh `just court` legs + warm-up suite)
Date: 2026-10-17
Gate: `bash scripts/court_x2.sh` (two fresh `just court` legs; both must be 0 failures)
Log: `tmp/court-x2-v17-wrap3.log`, `COURT_X2_RC=1` (line 86)

## Sequence executed (with real output)

1. `just quiet-check` — RC=0: `QUIET-CHECK: clear (beams ok, ports free, no
   concurrent suites, load 6.3 < 16)` (tmp/quiet-check-a3-1.log)
2. `just quiesce` warm-up — **RC=2: warm-up full offline suite FAILED**
   (1 failure, 2655 tests, 302.5s; tmp/quiesce-a3.log)
3. `just quiet-check` (post-warm-up) — RC=0: `load 9.0 < 16`
   (tmp/quiet-check-a3-2.log)
4. `bash scripts/court_x2.sh` — **FAILED**: Run 1 = 4 failures, Run 2 = 1
   failure, both runs `test-offline` exit 2, gate RC=1.

## Contemporaneous full-log runs (identities; court_x2 tails carry full test
identities at log lines 66-78 — an earlier draft of this receipt wrongly said
they "carry no test identities")

| Run | Failures | Identities |
|---|---|---|
| court run 1 (wrap3.log line 68) | 4 | incl. WasmEngineFailClosed "restart hammer" fence 10 (:502) |
| court run 2 (wrap3.log line 72) | 1 | **WasmEngineFailClosed "restart hammer" fence 10 (:502) — REPEAT** |
| pre-court full (tmp/mix-test-a3-full.log) | 2 | WasmEngineFailClosed "restart hammer" (timing face, 129ms > bound); EgressDispatch setup ETS `:smalt_subscriptions` "table identifier does not refer to an existing ETS table" |
| post-court full (tmp/mix-test-a3-postcourt.log) | 2 | SmaltLroTest :543 op-record store miss (`:error` vs Succeeded); EgressDispatchTest :975 setup — SAME ETS leak mechanism |

## Solo verification (Chicago: real state, all RC=0, 1 test 0 failures)

- test/affidavit_wasm_failclosed_test.exs:502 — solo PASS
- test/egress_dispatch_test.exs:1474 — solo PASS
- test/lro_test.exs:543 — solo PASS
- test/egress_dispatch_test.exs:975 — solo PASS

## Pre-mortem predictions — what held

- **Held**: quiet-check gate preconditions (idle machine, free ports) — clear
  both passes.
- **Held**: failure-identity shift PARTIALLY — 4+ distinct identities across
  the window, BUT this attempt breaks r240's no-repeat structure: fence 10
  (WasmEngineFailClosed :502, log lines 68 + 72) failed in BOTH court legs.
  Correction to an earlier draft of this receipt (skeptic-catch): the
  "zero repeats of a full (test, mode) face between the two court legs" claim
  is FALSE for attempt 3. Fence 10 is therefore upgraded from CONTENTION to a
  **PERSISTENT FLAKE FACE** (repeats under court load, solo-green): it needs a
  real fix (bound slack or harness de-parallelization), not just a warm-up.
- **Did NOT hold**: the #1 mitigation (quiesce warm-up absorbs cold-run-1 load
  faces). The warm-up suite itself failed before court-x2 launched, and
  court run 1 still tripped 4 faces. Warm-start does not de-conflict the
  async teardown race; it only clears machine-level load.
- **Did NOT hold**: two-green on attempt 3.

## Disposition

Every tripped face is solo-green on the same tree. One face (fence 10)
repeated across both legs of this attempt — typed PERSISTENT-FLAKE, not
contention-shifting; the remaining faces (EgressDispatch setup ETS
`:smalt_subscriptions` teardown race, victims :1474/:975; Lro :543 op-record
store miss) are contention-class with a named shared mechanism. WO-2 closes
**honest TYPED-RED** per the r240 fallback and WORK_ORDERS.md: gate not
cleared this window; NEXT_WINDOW carries it with the r240→r241 chain. The
repair surfaces (noted for the next window, not landed here): (a) fence 10's
129ms-vs-bound timing bound needs slack or harness serialization; (b)
EgressDispatchTest setup seeds `:smalt_subscriptions` via
`Smalt.Store.seed_default_subscription/0` (lib/smalt/store.ex:194) racing
another async module's Store teardown — async-module isolation, not a product
defect.
