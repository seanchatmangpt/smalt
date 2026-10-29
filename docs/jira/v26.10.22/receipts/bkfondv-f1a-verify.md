# BK-FONDV — F1-A false-refusal fix independent verification

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-FONDV (read-only verify), canonical checkout /Users/sac/smalt,
  MIX_BUILD_ROOT=_build-bkfondv (left for coordinator `just lane-clean`)
- **Audits**: docs/jira/v26.10.22/receipts/bkfondsd-repairs.md (F1-A claimed
  CLOSED), docs/jira/v26.10.22/receipts/bkfondskep-runner-audit.md (original
  15-shape probe, 5 DIVERGE lines)

## Method

BK-FONDSKEP's probe script survived at /tmp/bkfondskep_probe.exs; re-ran its
T1 shape set verbatim (fresh /tmp/bkfondv_probe.exs, same 15 shape literals,
same real `assert_acyclic/1` vs real `next_ready/2` fixpoint simulation,
fuel-bounded) plus real `run/1` refusal legs through the real gen_statem
runner. Fresh build root _build-bkfondv, current tree, `mix run --no-start`.

## (1) 15-shape probe: 14/15 AGREE — one residual divergence

```
linear: planner=:ok executor=:executable => AGREE_EXEC
diamond: planner=:ok executor=:executable => AGREE_EXEC
fork: planner=:ok executor=:executable => AGREE_EXEC
join: planner=:ok executor=:executable => AGREE_EXEC
mixed_provides: planner=:ok executor=:executable => AGREE_EXEC
unprovided: planner={:unprovided_need, [a: :never_provided]} executor={:not_executable, [:a]} => AGREE_UNPROVIDED
cycle: planner={:cyclic_plan, [:a, :b]} executor={:not_executable, [:a, :b]} => AGREE_CYCLE
self_need: planner={:cyclic_plan, [:a]} executor={:not_executable, [:a]} => AGREE_CYCLE
dup_provider: planner=:ok executor=:executable => AGREE_EXEC
dup_provider_min: planner=:ok executor=:executable => AGREE_EXEC
empty: planner=:ok executor=:executable => AGREE_EXEC
done_id_only: planner=:ok executor=:executable => AGREE_EXEC
dup_ids: planner={:cyclic_plan, [:a]} executor=:executable => DIVERGE-PLANNER-REFUSES-EXECUTABLE
diamond_mixed: planner={:unprovided_need, [m: :rxx]} executor={:not_executable, [:m, :t]} => AGREE_UNPROVIDED
late_provider: planner=:ok executor=:executable => AGREE_EXEC
T1 DIVERGENCES: 15 [[], [], [{"dup_ids", "DIVERGE-PLANNER-REFUSES-EXECUTABLE"}], [], [], [], [], [], [], [], [], [], [], [], []]
```

The probe's own divergence counter printed the unflattened comprehension
result (15 elements, 14 empty lists, 1 match) — same probe-side quirk class
the audit disclosed; the per-shape lines are the evidence: exactly 1
DIVERGE shape.

4 of the 5 audit DIVERGE shapes now AGREE (join, done_id_only, dup_provider,
dup_provider_min). The 5th (dup_ids: two steps both `id: :a`, no needs, no
provides) still false-refuses as `{:cyclic_plan, [:a]}` while the executor
executes. BK-FONDSD's receipt named dup-ids among shapes "no longer
false-refused" — that claim does not hold as landed.

## (2) Accept-direction: both refusal directions intact, typed

Real run/1 through the real gen_statem (no mocks):

```
unprovided_need guard (witness shape) => {:returned, {:crash, {{:unprovided_need, [b: :never_provided]}, [smalt_fond_plan:assert_acyclic/1, ...]}}}
unprovided_need guard (mid-chain ghost) => {:returned, {:crash, {{:unprovided_need, [b: :ghost]}, [assert_acyclic/1, ...]}}}
unprovided_need guard (self-need) => {:returned, {:crash, {{:cyclic_plan, [:s]}, [smalt_fond_plan:kahn/5, ...]}}}
cyclic_plan guard => {:returned, {:crash, {{:cyclic_plan, [:a, :b]}, [smalt_fond_plan:kahn/5, ...]}}}
```

No accept-direction hole: truly unprovided needs still refuse typed before
execution (assert_acyclic, line 76), real cycles still refuse as
cyclic_plan. Note: self-need (`s needs :s`, no provides) now refuses as
`cyclic_plan` where the audit recorded `unprovided_need` — still a typed
pre-execution refusal, correctly classified by the repaired precheck (the
need IS a step id, so it passes the Unprovided precheck and Kahn pins it as
a cycle — arguably the more precise verdict), not a regression.

## (3) "mirrors exactly" comment — still prose

`lib/smalt/pipeline/smalt_fond_plan.erl:79-81` (needs_sat/3 doc): "This
mirrors next_ready/2 exactly" — not true as landed. The residual dup_ids
divergence IS the counterexample: Kahn's `Done` is id-keyed but
`length(Ids)` counts duplicates, so duplicated step ids can never reach
`maps:size(Done) =:= length(Ids)` and false-refuse as cyclic_plan, while
next_ready's id-keyed done-set silently collapses duplicates and runs.
14/15 is not "exactly". Either dedup `Ids` in assert_acyclic/1 (making the
planner accept dup-id plans the executor runs) or make next_ready/1
duplicate-aware — either way the comment should be true before F1-A stands
as closed. (Duplicate step ids in one plan are likely malformed input; but
then the refusal class should be a typed dup-id error, not cyclic_plan.)

## (4) Fresh court legs (this lane's build root)

```
MIX_BUILD_ROOT=_build-bkfondv mix test test/internal/expl10r_court_test.exs --include expl10r_f1a
  → Result: 15 passed, exit 0
MIX_BUILD_ROOT=_build-bkfondv mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
  → Result: 29 passed, exit 0 (first grep of a concurrent run showed "28/29" mid-flight; captured rerun: 29 passed)
```

## Verdict

F1-A is **not fully closed**. The dangerous accept-direction divergence
remains closed (0 shapes; all four refusal legs typed and pre-execution),
and 4/5 audited false-refusal shapes are repaired. But the 15/15 bar for
ALIVE is not met: dup_ids still diverges (false-refusal direction,
availability class, not safety), and the "mirrors exactly" comment is
contradicted by the probe. PARTIAL_ALIVE with typed finding:

- **BK-FONDV-1 (MEDIUM, pre-existing corner)**: duplicate step ids —
  planner `{:cyclic_plan, [dup]}` vs executor runs; close by deduping
  `Ids` in assert_acyclic/1 or typing the dup-id refusal, then re-run this
  probe (15/15 required).

## Falsifiers

- A repair of dup_ids that still shows a DIVERGE line in this probe
  re-opens BK-FONDV-1.
- Any of the four refusal legs returning `{:ok, _}` / sealing re-opens the
  accept-direction question.
- Any of the 15/15 shapes flipping away from AGREE re-opens F1-A.
- The 15 expl10r_f1a legs and 29 fond-court legs are regression guards.
