# V261019-12 — Court-x2 close: 11-stage new court, two greens at a pinned SHA

- **Release:** v26.10.19
- **Lane:** court-x2-close
- **Base:** post-deletion HEAD (descendant of the V261019-11 commit)
- **Status:** draft — BLOCKED until V261019-11 lands

## Objective

Define and land the **new 11-stage admission court** for the clean-room
tree, run it to the release receipt law — **two consecutive fresh green
courts at one pinned SHA** (`scripts/court_x2.sh` law: both runs exit 0 AND
both summary lines show 0 failures; run1/run2 failing on different tests is
the flake signature) — and preserve the documented exit contracts of every
stage.

## The 11 stages

| # | Stage | Source of truth | Exit contract preserved |
|---|---| |---|
| 1 | `doctor` | `scripts/doctor.py` via `just doctor` | 0 pass / nonzero fail (typed preflight) |
| 2 | `test-offline` (residual) | `Justfile` stage over `test/internal/` | 0 failures; SKIP semantics loud |
 loud |
| 3 | `sdk-ts-court` | `justfile.d/04-sdk-recipes.just` `sdk-ts` probes | 0 pass / 1 fail / 3 SKIP-loud (env absent) |
| 4 | `sdk-py-court` | `sdk-py` recipe (`test/sdk-python/run.sh`) | same 0/1/3 contract |
| 5 | `tf-plan-smoke` | `just tf-plan-smoke` | apply/destroy < 30s; 0/1/3 exit contract |
| 6 | `bench-check` | `just bench-check` (stale-receipt refusal) | 0 fresh / nonzero stale-or-missing |
| 7 | `mutation-court` | `scripts/mutation_court.py` | 0 non-vacuous / 1 vacuous / 2 BLOCKED — never softened |
| 8 | `census` | `just census` over surviving tiers | nonzero on hollow/silent-tag-loss |
| 9 | `invariant-gates` | `just invariant-gates` | nonzero on any gate red |
| 10 | `naming-sweep` | `just naming-sweep` | nonzero on forbidden-name hits |
| 11 | `sleep-gate-sdk` | NO-SLEEP-DOCTRINE grep over sdk harnesses | nonzero on any `sleep` hit in test-facing sdk code |

Stages 1–10 map to the existing `just court` members; stage 11 joins the
court in this release. `court` body rewired post-deletion (V261019-11) to
the residual surface; stage 11 appended; the stage ORDER above is the court
order.

## Preconditions

- V261019-11 landed: deletion commit exists, compile green, dangling-ref
  census 0, residual tier green, recipes rewired loud.
- Residual tier (V261019-10) landed before the gate window opens.
- Court runs at a pinned SHA: `git rev-parse HEAD` echoed at court start;
  refuse if the tree is dirty; fail the receipt if HEAD moves mid-court.

## Execution

1. Rewire `just court` (Justfile ~line 201) to the 11-stage list; append
   `sleep-gate-sdk` (a small grep script, e.g.
   `scripts/sleep_gate.py --scope sdk-harnesses` following the B8 doctrine
   gate shape: lib/ PASS 135 files 0 sleeps was the exemplar).
2. `scripts/court_x2.sh` unchanged in law: two fresh `just court` runs, no
   reuse; the green predicate still rejects compile-abort-with-zero-failure
   logs (vacuous green); failure-set diff run1 vs run2 printed on any
   non-green.
3. Run court-x2 at the pinned SHA with
   `MIX_BUILD_ROOT=_build-ft-cx2 just court-x2`.
4. **Exit-contract preservation:** for each of the 11 stages, the receipt
   records the witnessed exit code and the contract row above must still
   hold. A stage whose contract changed (e.g. a retired recipe now exiting
   0) is a court failure — fix the wiring, not the contract.
5. **Retired-stage hygiene:** any stage touching deleted tiers runs as the
   loud `[RETIRED]` no-op from V261019-11 and is treated as SKIP-loud, never
   as pass.

## Close conditions

- `MIX_BUILD_ROOT=_build-ft-cx2 just court-x2` — run 1 GREEN, run 2 GREEN,
  failure-set diff empty; HEAD pinned and echoed in the receipt; no HEAD
  movement during either run.
- All 11 stage exit contracts witnessed unchanged (table above, receipts
  per stage).
- Exit-contract table lands in
  `docs/jira/v26.10.19/receipts/v12-court-x2-close.md` together with both
  court logs' tail summaries.
- Register flip: the v26.10.19 WORK_ORDERS row for the court-x2 close flips
  receipt-gated, citing this receipt.
- **Third-strike rule:** a third consecutive court-x2 failure retires the
  court shape itself (same law as the burn-ring third strike) — the lane
  must then re-derive the court, not iterate it.
