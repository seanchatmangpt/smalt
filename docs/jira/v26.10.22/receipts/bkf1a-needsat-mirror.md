# BK-F1A — needs_sat/3 ≡ next_ready/2 mirror repair (BK-FONDSKEP F1-A)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-F1A, canonical checkout /Users/sac/smalt, MIX_BUILD_ROOT=_build-bkf1a
- **Audit input**: docs/jira/v26.10.22/receipts/bkfondskep-runner-audit.md (F1-A, HIGH: 5/15 property shapes diverge, all false-REFUSAL)

## What landed

1. **lib/smalt/pipeline/smalt_fond_plan.erl — needs_sat/3 mirror law.**
   The F1-A code repair (done-id arm in the `Unprovided` precheck;
   multi-provider `Providing` map `term -> [id()]`; `needs_sat/3` checking
   "some done provider") was already in-tree when this lane opened (landed
   via tick-checkpoint snapshot class; the plan file was git-clean at lane
   open). This lane verified the repair against the audit's falsifier and
   completed the remaining artifacts. This lane's lib delta is the
   `needs_sat/3` doc comment only: it now names the two arms of the law
   (done-id arm + any-done-provider arm) and cites the F1-A court, so the
   "mirrors exactly" claim is court-backed.
2. **Court legs** in test/pipeline/fond_powl_runner_court_test.exs,
   describe "court (f) F1-A needs_sat ≡ next_ready mirror (bkfondskep)":
   15 per-shape legs (each asserts planner class == executor class ==
   expected class, where the executor class comes from a real bounded
   `run/1`) + a full 15-shape sweep leg asserting zero divergences.
   Real collaborators throughout (real `assert_acyclic/1`, real
   `run/1` in a spawned bounded process), no mocks.
3. **Receipt** (this file).

## Falsifier — 15/15 AGREE_OK (real run/1 probes)

Command: `MIX_BUILD_ROOT=_build-bkf1a mix run --no-start /tmp/bkf1a_probe.exs`. Verbatim:

```
linear: planner=:executable executor=:executable expected=:executable => AGREE_OK
diamond: planner=:executable executor=:executable expected=:executable => AGREE_OK
fork: planner=:executable executor=:executable expected=:executable => AGREE_OK
join: planner=:executable executor=:executable expected=:executable => AGREE_OK
mixed_provides: planner=:executable executor=:executable expected=:executable => AGREE_OK
unprovided: planner={:refused, :unprovided_need} executor={:refused, :unprovided_need} expected={:refused, :unprovided_need} => AGREE_OK
cycle: planner={:refused, :cyclic_plan} executor={:refused, :cyclic_plan} expected={:refused, :cyclic_plan} => AGREE_OK
self_need: planner={:refused, :cyclic_plan} executor={:refused, :cyclic_plan} expected={:refused, :cyclic_plan} => AGREE_OK
dup_provider: planner=:executable executor=:executable expected=:executable => AGREE_OK
dup_provider_min: planner=:executable executor=:executable expected=:executable => AGREE_OK
empty: planner=:executable executor=:executable expected=:executable => AGREE_OK
done_id_only: planner=:executable executor=:executable expected=:executable => AGREE_OK
dup_ids: planner=:executable executor=:executable expected=:executable => AGREE_OK
diamond_mixed: planner={:refused, :unprovided_need} executor={:refused, :unprovided_need} expected={:refused, :unprovided_need} => AGREE_OK
late_provider: planner=:executable executor=:executable expected=:executable => AGREE_OK
T1 RESULT: 15/15 AGREE_OK; divergent/failed: []
```

The five witness shapes — **join, done_id_only, dup_ids, dup_provider,
dup_provider_min** — all flip to `:executable` on both planner and real
executor. The genuinely-cyclic/unprovided shapes (unprovided, cycle,
self_need, diamond_mixed) still refuse typed, with planner class ≡
executor class on every shape.

## Court output (embedded, verbatim)

```
$ MIX_BUILD_ROOT=_build-bkf1a mix test test/internal/expl10r_court_test.exs test/internal/expl10r2_court_test.exs test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
Finished in 0.6 seconds (0.00s async, 0.6s sync)
Result: 55 passed
```

Fond court standalone (incl. F1-A legs, skeptic tag included): `Result: 29 passed`.

## Disclosures

- **The F1-A lib repair itself was already in-tree** at lane open (the
  dispatch expected to apply it; it was present via a tick-checkpoint
  snapshot). Verified: the plan file was git-clean at `6f5db293`. This
  lane's lib diff is the doc comment only; falsifier, court legs, and this
  receipt are this lane's work. Honest note (mirroring BK-F6R's): the
  dispatch named bkfondskep-runner-audit.md — it exists and was read in
  full (the BK-F6R receipt said its dispatch's named file did not exist;
  different lane, different outcome).
- **self_need label correction**: the audit labeled self_need
  AGREE_UNPROVIDED; on the current tree BOTH planner and executor refuse
  `{:refused, :cyclic_plan}` (the need is a member of Ids, so the
  Unprovided precheck lets it through to Kahn, which cannot ready it).
  The equivalence law under test (planner ≡ executor) holds; only the
  audit's label was loose, not the code. Court expectation pinned to
  `{:refused, :cyclic_plan}`.
- First draft of this receipt was written corrupted and was fully
  rewritten in place (same path) before commit; the version committed is
  this one.
- Probe scripts live in /tmp (bkf1a_probe.exs), not the repo. No other
  files touched.

## Standing checks (falsifiers that would re-open F1-A)

- Any of the 5 witness shapes refusing in `assert_acyclic/1` or in a real
  `run/1` re-opens F1-A.
- Any planner admission where the executor refuses (the dangerous
  accept-direction) re-opens F1-A at HIGH.
- The 15-shape court failing on a clean tree re-opens F1-A.
