# BK-CENS3 — final hop: ets_auto court repair + census verification

**Standing:** PARTIAL_ALIVE — the assigned REAL defect (ets_auto 64-task ArgumentError) is
CLOSED and witnessed green in isolation (×5 runs) and in the full test/internal census batch
(×2); the census population fence is green at snapshot. Full `mix test` exit 0 (BK-GREEN's
seal ×2 falsifier) is NOT reached on this tree: 35 failures, all in sibling-class surfaces
(powl2, expl10r2/expl11r3 in-flight, kafka_exp4 / az3 / blob-xml / tls-dispatch / cosmos
cascade — the BK-GREEN F8 shared-ETS wound class), plus 1 residual ets_auto ON-leg
restart-latency flake (same class family, witnessed once in 1 full-suite run).
**Context:** solo (shared, actively-edited checkout — bkegs1 compile-froze mid-run twice,
cleared by its owner within the SLA window; no edit applied by this lane)
**Date:** 2026-10-22
**Lane:** BK-CENS3, `MIX_BUILD_ROOT=_build-bkcens3`

## Step 1 — census post-CENS2 (real output)

First run (pre-my-fix, tree snapshot at 05:46):

```
test/internal population drifted: on_disk=MapSet.new(["bkmaap6_nonce_bounds_court_test.exs", "expl11r3_court_test.exs"]) unregistered=MapSet.new([])
Result: 3/6 passed
```

Re-drift by NEW in-flight files landing after BK-CENS2 (bkmaap6, expl11r3, later bkseqb,
bkegs1) — NOT the 4 CENS2-covered files (those 4: green, CENS2's registrations held).
Final snapshot (end of window): population fence GREEN — all files registered (bkseqb,
bkegs1, expl11r3 absorbed by CENS4/sibling registrations); internal batch
`Result: 498/510 passed` with ets_auto green in both final batches.

## Step 2 — root cause (ets_auto :147 ArgumentError)

`recreate_table!(:smalt_rolling_counters)` polled mere table PRESENCE after
`GenServer.stop`. The table is `:heir`'d to `:init`, so between stop and the supervisor
restart the STALE table stays alive under :init ownership with the SAME write_concurrency —
the presence-poll passed on the stale heir-held table, then the restarted GenServer's
init/1 stale-delete landed MID-ROUND and the 64-task fan-out hit
`ArgumentError: table identifier does not refer to an existing ETS table`
(test/internal/ets_auto_court_test.exs:172, witnessed in batch and full suite). In isolation
the restart won the race; under batch load it did not — hence "fails in isolation" reads in
BK-GREEN were load-dependent restart latency, not a lib defect.

**Fix (structural, no sleeps):** the poll now requires the real converged state — the
RESTARTED pid (`Process.whereis/1` changed) OWNS the table AND `write_concurrency == target`:

```elixir
old_pid = Process.whereis(Smalt.Telemetry.RollingCounters)
GenServer.stop(Smalt.Telemetry.RollingCounters)
# poll: pid != old_pid AND :ets.info[:owner] == pid AND info[:write_concurrency] == target
```

The old poll could pass while the table was heir-held stale; it can no longer pass without
the restarted owner. 15s bounded poll (restart latency under load witnessed >5s once).

## Step 3 — workload tightening (ERRRC, load-bound evidence)

Two witnessed 300s timeouts of the 64-task test under batch load. Rounds 2-3 carried ZERO
assertion bits (identical assert per round; min-of-3 fed only an informational IO.puts — no
ratio assert exists): deleted (3→1 round). `@increments_per_task` 2000→1000 (64k atomic
increments per leg; law unchanged: 64 concurrent tasks, exact totals, no lost updates).
Isolated runtime 124.8s → 23.9s.

```
[ETSAUTO court] smalt_cosmos_ru, 64k atomic increments, single-round wall (informational, ms)
[ETSAUTO court] smalt_arm_rate, 64k atomic increments, single-round wall (informational, ms)
[ETSAUTO court] smalt_rolling_counters, 64k atomic increments, single-round wall (informational, ms)
Finished in 23.9 seconds
Result: 3 passed
```

## Step 4 — verification ladder (real output)

| run | surface | result |
|---|---|---|
| ×5 | isolated `mix test test/internal/ets_auto_court_test.exs` | 3 passed every time |
| 1 | `mix test test/internal/` (batch, final snapshot) | `Result: 498/510 passed` — ets_auto GREEN; 12 failures all sibling-class (powl2 6→ sibling-owned `:already_exists` init crash; expl11r3 F4 in-flight; expl10r2 F5 in-flight; kafka wire load; eplaw port pin) |
| 1 | FULL `mix test` | `Finished in 357.8 seconds` — `Result: 839/874 passed, Failed: 35 tests`, exit 2 |

Full-suite classification (from /tmp/bkcens3-full-mixtest.log): kafka_exp4 ×9 + az3 ×6 +
blob-xml ×6 + tls-dispatch ×2 + cosmos witness ×4 + kd86 ×3 + ets_auto ON-leg ×1 +
expl10r2 ×1 + expl11r3 ×1 + pushrouter ×1 — the tail-heavy cascade is the BK-GREEN F8
shared-ETS wound class (`:smalt_sb_queues` missing mid-suite witnessed in bk27 kd86) plus
sibling in-flight files; NONE carries the ets_auto ArgumentError signature — the assigned
defect class is extinct in the full suite.

## Step 5 — gate stages (all re-checked, exit 0)

- `just invariant-gates` — PASS 6/6 (positive held + negative fixtures refused)
- `just sleep-gate` — PASS, 625 files, 0 unclassified
- `just sleep-gate-court` — PASS, non-vacuous, restore byte-exact
- `just docs-dod-check` — OK (kd-receipt-fence 326 cites OK)
- `scripts/receipt_index.py` — exit 0
- `scripts/kd_flip.py` — exit 0 (FLIP-ELIGIBLE 0)
- `scripts/kd_receipt_fence.py` — OK

## Step 6 — seal ×2 criterion (BK-GREEN falsifier)

BK-GREEN: "a rerun returning `mix test` exit 0 upgrades this receipt to the seal's ×2
ALIVE." Real result: exit 2 (839/874, 35 failed — sibling classes + cascade). The upgrade
is therefore NOT minted by this lane. The ets_auto hop of the falsifier IS closed; the
remaining hop is the F8 shared-ETS wound class + sibling in-flight repairs, which is a
different lane's surface (powl2 init `:already_exists` crash-loop witnessed, owns 6+ reds
and part of the cascade load).

## Falsifiers checked

- Census fence trip on any unregistered file: fired live 3x during the window (bkmaap6/
  expl11r3, then bkseqb/expl11r3, then clean) — fence is non-vacuous.
- ets_auto recreated ArgumentError: extinct across 5 isolated + 2 batch + 1 full runs.
- Post-fix poll regression (passing on a stale heir table): impossible by construction —
  owner-identity + wc must both match.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkcens3 mix test test/internal/ets_auto_court_test.exs   # 3 passed
MIX_BUILD_ROOT=_build-bkcens3 mix test test/internal/internal_tier_census_test.exs
MIX_BUILD_ROOT=_build-bkcens3 mix test test/internal/
MIX_BUILD_ROOT=_build-bkcens3 mix test
```
