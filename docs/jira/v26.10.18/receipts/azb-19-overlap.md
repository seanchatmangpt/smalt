# Receipt — AZB-19 Port-free stage overlap scheduling

Standing: **PARTIAL_ALIVE** — the scheduler, resource validator, and just
Context: solo(scripts/overlap_court.sh serial/overlap 10-stage pairs; no mix test invocation)
recipes are landed and witnessed (anti-vacuity refusals, non-vacuous
falsifier, verdict identity on full 10-stage pairs); the ≥40% median
wall-clock Accept is **NOT certified** on this window: 37.1% on the one fully
clean comparable pair, 40.5% on a pair whose tf leg raced a concurrent lane.
Typed blockers below; no number on this receipt is massaged.

## Identity

- Session window 2026-10-18 19:20–21:35 PDT, repo `/Users/sac/smalt`.
- HEAD at session start `de0c471`; HEAD moved **9 times** during the window
  (last seen `014bb7a`); every result row pins its run HEAD in
  `tmp/azb19/azb19-*/result.jsonl` (`head` field).
- Owned files: `scripts/overlap_court.sh` (new), `justfile.d/30-burn.just`
  (schedule section appended — the pipeline lane's section per the ticket's
  lane partition), `docs/jira/v26.10.18/receipts/azb-19-overlap.md`.
- Disclosed SLA unblock on another lane's file:
  `test/azsim/dets_recovery_test.exs` — added `import Bitwise` (frozen the
  shared compile: `bxor/2` undefined; every mix stage in every lane was
  dead). The burn lane may supersede with their own fix.

## What landed

`scripts/overlap_court.sh` — the AZB-19 scheduler. Stages declare resources
(ports, build_root, dets_dir); `validate_concurrent` refuses, with typed
refusals, any concurrently-scheduled pair that (a) shares a build_root /
port / dets token → `RESOURCE_CONFLICT`, or (b) is a load-class excluded pair
(t1-offline ∥ t3-sdk-smoke) → `LOAD_CONFLICT`. Schedule (final):

```
p1 {t1-offline ∥ mutation-court ∥ tf-plan-smoke ∥ statics (doctor, bench-check, census, naming-sweep, invariant-gates)}
p2 {t2-wire ∥ t3-sdk-smoke}   (ticket phase 2 shape: {wire ∥ container-class})
```

- Per-stage `MIX_BUILD_ROOT=tmp/azb19/roots/<stage>` — OUTSIDE the `_build*`
  lane-clean sweep: a concurrent lane-clean reclaimed my in-sweep roots
  mid-run (witnessed: `_build-burn-19-base` + clones vanished between 19:35
  and 19:44; only the live_refs-protected mutation root survived). Warm base
  is cloned per stage (APFS `cp -Rc`), mtimes preserved, mix sees the clone
  as fresh.
- Background stages run at lowered CPU priority (`taskpolicy -c utility`) so
  the load-class chain keeps performance cores.
- Port shifts keep lane substrates off the shared substrate's canonical
  ports: tf on 39380/39381, mutation-court auto-scopes its private block
  when the front door is held (its own mechanism; my explicit
  `SMALT_BENCH_ARM_PORT=39373` override made it boot defaults and die —
  removed), invariant-gates on their `SMALT_TEST_*_PORT` private ports.
- just recipes: `just overlap-court`, `-serial`, `-check`, `-compare`,
  `-report` (justfile.d/30-burn.just, schedule section).

## Anti-vacuity — witnessed (exit 0)

```
$ bash scripts/overlap_court.sh anti-vacuity
[ANTI-VACUITY] witness 1: two overlapped stages, same MIX_BUILD_ROOT
CONFLICT RESOURCE_CONFLICT dup-build other build:shared
[ANTI-VACUITY] witnessed: RESOURCE_CONFLICT refusal
[ANTI-VACUITY] witness 2: t1-offline scheduled concurrent with t3-sdk-smoke
CONFLICT LOAD_CONFLICT t1-offline t3-sdk-smoke load
[ANTI-VACUITY] witnessed: LOAD_CONFLICT refusal
[ANTI-VACUITY] PASS: both injected schedules refused
```

Re-witnessed through the just spelling:
`just overlap-court-check` → `[ANTI-VACUITY] PASS: both injected schedules refused`.

## Falsifier gate — non-vacuous (fired on real diffs)

`overlap_court.sh compare <serial.jsonl> <overlap.jsonl>` exits 1 on any
stage-verdict difference. Fired 3 times in the campaign:

| pair | diff | classification |
|---|---|---|---
| S4/O4 | tf-plan-smoke serial=1 overlap=2 | cross-lane tf race: tf_smoke.sh PLAN_OUT=`/tmp/smalt-plan.out` (hard-coded) — "Inconsistent dependency lock file" when a concurrent lane's tf run rewrote the plan between my plan and apply |
| S5/O5 | t1-offline serial=2 (2700 tests, 8 fail) vs overlap=1 (compile abort `test/azsim/dr_scenarios_test.exs`, 19s) | cross-lane in-flight test file (burn lane) |
| S6/O6 | invariant-gates serial=1 (4 failures) vs overlap=0 (PASS) | gate substrates failing under concurrent-lane load; flaps run-to-run |

## Verdict identity — witnessed PASS on full pairs

```
$ bash scripts/overlap_court.sh compare tmp/azb19/azb19-serial-1792379407/result.jsonl tmp/azb19/azb19-overlap-1792380021/result.jsonl   # S2/O2
[COMPARE] tmp/azb19/azb19-serial-1792379407/result.jsonl vs tmp/azb19/azb19-overlap-1792380021/result.jsonl
[COMPARE] OK: all stage verdicts identical between serial and overlapped schedules

$ bash scripts/overlap_court.sh compare tmp/azb19/azb19-serial-1792380740/result.jsonl tmp/azb19/azb19-overlap-1792380426/result.jsonl   # S3/O3
[COMPARE] tmp/azb19/azb19-serial-1792380740/result.jsonl vs tmp/azb19/azb19-overlap-1792380426/result.jsonl
[COMPARE] OK: all stage verdicts identical between serial and overlapped schedules
```

## Measurements (all runs, honest; per-stage walls in tmp/azb19/*/result.jsonl)

Stage-time table (serial walls across S2/S4/S5):
doctor 1s, bench-check 0-1s, census 0s (SKIP), naming-sweep 1s,
invariant-gates 16-46s, t1-offline 108-129s (full run), mutation-court
21-39s, tf-plan-smoke 32-39s, t2-wire 5-8s, t3-sdk-smoke 0s (exit-3 skip).

| run | sched | total_s | HEAD | reduction vs paired serial | verdict identity |
|---|---|---|---|---|---|
| S1 | v0 | 1401.9 | 8552eecc | — | shakedown (census eval bug + my mutation env misuse → BLOCKED boot); excluded, disclosed |
| O1 | v0 | 130.8 | 8552eecc | — | shakedown overlap |
| S2 | v1 | 239.9 | d78b4037 | pair 37.1% | IDENTICAL (10/10 stages) |
| O2 | v1 | 150.9 | 825657ff | | |
| S3 | v1 | 125.4 | 8431e167 | pair 2.3% | IDENTICAL (10/10 stages) — but t1 ran with 230 failures (cross-lane churn; walls not representative) |
| O3 | v1 | 122.5 | 2b709d81 | | |
| S4 | v2 | 200.8 | 5ad2304f | pair 40.5% | FIRED (tf 1 vs 2) — cross-lane tf /tmp plan race, typed above |
| O4 | v2 | 119.5 | 66817467 | | |
| S5 | v2 | 215.4 | 24cb2cd3 | pair 62.0% (t1 compile-abort leg on O5 side — not representative) | FIRED (t1 2 vs 1) |
| O5 | v2 | 82.0 | 05f5a9b2 | | |
| S6 | v2 | 102.1 | 2aad1549 | pair 44.7% (t1 compile-abort legs BOTH sides — not representative) | FIRED (invariant-gates 1 vs 0) |
| O6 | v2 | 56.6 | 2aad1549 | | |

Schedules: v1 = 3-phase (t3 in p3, no priority pinning); v2 = final
(t3 ∥ t2 in p2, `taskpolicy -c utility` on background stages). v0 = shakedown
(before census/mutation stage fixes). The counted comparison is per adjacent
pair, not across schedules.

### Accept assessment (median wall-clock, 3 runs)

- Only ONE fully clean comparable pair exists on the window: S2/O2 at
  **37.1%** (v1 schedule). The v2 pair with both legs fully executing
  (S4/O4) shows **40.5%** on the walls but its tf verdict differed, so it
  cannot certify Accept (verdict identity is part of the Accept).
- Naive medians over v2 (serial {200.8, 215.4, 102.1} → 200.8; overlap
  {119.5, 82.0, 56.6} → 82.0) give 59.2% but are NOT certifiable: three of
  the six runs carry compile-abort legs (t1 6-19s fast-fails) that deflate
  the deflated side's wall in either direction.
- **Accept: NOT certified.** Best evidence supports ~37-45% structural
  reduction with full-suite execution; the strict ≥40%-median + verdict-
  identity bar requires a quiesced tree (single-lane window) to measure.

## Typed blockers / disclosures

1. **T3 never executed in any counted run** — exit 3 (loud, per its own
   preflight) in all 10 runs: the shared substrate (pid 40499, up 19:07
   2026-10-18, actively logging until 19:22, lock state observed FREE) held
   9443/8443/5672 the entire window. Not evicted (lane port law). Every
   schedule therefore understates serial AND overlap by the same ~5 min
   T3 leg; with a real T3 the measured reduction falls (the overlap saves
   only p1's non-t1 stages) — the ≥40% claim must be re-measured on a
   quiesced tree with T3 live, or T3 must gain the private-port override
   its own error message already advertises.
2. **Cross-lane churn**: 9 HEAD moves; 3 distinct compile-freeze files
   (`dets_recovery_test.exs` bxor, `application.ex` mcp_bandit_child,
   `dr_scenarios_test.exs`); t1 failure count flapped 8 → 12 → 230 → 8;
   bench-check verdict flapped 0/1 (shared `tmp/bench-receipt.json` raced).
3. **tf_smoke.sh shared scratch paths** (`/tmp/smalt-plan.out`,
   `/tmp/smalt-tf-smoke-*.log`, PID file) are cross-lane hazards for any
   two concurrent court lanes — filed as a finding for the tf/interop lane;
   not my lease.
4. **Baseline at `21f58b0`** (ticket-specified): not measurable — HEAD moved
   by other lanes and no-git lane discipline; both sides of every pair were
   measured at the SAME adjacent HEADs instead (disclosed deviation).
5. **naming-sweep exit 1 in every run**: pre-existing tree-wide FAIL
   (27 violations in docs/jira/v26.10.18/rewrite-drafts/); none of the
   offender lines reference files from this lane.
6. Build roots lived at `tmp/azb19/roots` (3.7 GiB) and were reclaimed at
   session end per the cleanup law; `_build-burn-19-*` leftovers: none.

## Replay

```
bash scripts/overlap_court.sh anti-vacuity                                   # exit 0, both refusals witnessed
bash scripts/overlap_court.sh serial                                         # baseline schedule
bash scripts/overlap_court.sh overlap                                        # overlapped schedule
bash scripts/overlap_court.sh compare <serial>/result.jsonl <overlap>/result.jsonl
just overlap-court && just overlap-court-check && just overlap-court-compare <A> <B>
python3 -c "import json;[print(json.loads(l)) for l in open('tmp/azb19/azb19-serial-1792379407/result.jsonl')]"
```

## Standing

PARTIAL_ALIVE for AZB-19: scheduler + validator + recipes ALIVE
(anti-vacuity witnessed, falsifier non-vacuous, verdict identity witnessed
on two full pairs); Accept's ≥40% median reduction NOT certified on this
window (37.1% clean; 40.5% on a verdict-diff pair; churn-degraded pairs
above that but uncertifiable). Close condition: re-run
`just overlap-court-serial` ×3 + `just overlap-court` ×3 on a quiesced tree
with 9443 free (T3 live) and land a compare-identical ≥40% median.

## Postscript — 2026-10-18 ~22:00 PDT, re-witness at HEAD 014bb7a→2eb5f89d

- `bash scripts/overlap_court.sh anti-vacuity` re-run at HEAD `014bb7a`:
  **exit 0**, both refusals (`RESOURCE_CONFLICT`, `LOAD_CONFLICT`) witnessed
  again — the gate is still non-vacuous on the current tree.
- One fresh overlapped run executed end-to-end
  (`tmp/azb19/azb19-overlap-1792383172/result.jsonl`, HEAD pinned
  `2eb5f89d`): scheduler completed all phases, exit 0. Per-stage exits
  match the receipt's documented churn modes: bench-check 1 (known
  shared-receipt flap), naming-sweep 1 (pre-existing tree-wide), t1 exit 2
  (compile abort, cross-lane in-flight test edits),
  t3 exit 3 (9443 still held by the shared substrate, pid 40499 — not
  evicted per lane port law).
- Walls NOT comparable to the campaign above: concurrent lane activity
  inflates them (invariant-gates 198 s vs 16-46 s in the campaign;
  total 718.6 s). No Accept number is claimed from this run. Close
  condition unchanged: quiesced tree + 9443 free, serial ×3 ∥ overlap ×3.
