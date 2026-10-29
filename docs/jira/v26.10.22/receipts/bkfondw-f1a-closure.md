# BK-FONDW — F1-A closure verification (independent, dup-id fix confirmed)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-FONDW (read-only verify), canonical checkout /Users/sac/smalt,
  MIX_BUILD_ROOT=_build-bkfondw (left for coordinator `just lane-clean`)
- **Audits**: docs/jira/v26.10.22/receipts/bkdupid-dedup-fix.md (claimed 15/15),
  docs/jira/v26.10.22/receipts/bkfondv-f1a-verify.md (14/15, opened BK-FONDV-1)

## Method

Independent reconstruction of the 15-shape T1 probe (fresh literals, same 15
shape set as BK-FONDSKEP/BK-FONDV/BK-DUPID; fresh /tmp/bkfondw_probe.exs, not
a copy of any prior lane's script), real `assert_acyclic/1` vs real
`next_ready/2` fuel-bounded fixpoint simulation, plus real `run/1` refusal
legs through the real gen_statem runner — no mocks. Fresh build root
_build-bkfondw, current tree, `mix run --no-start`.

## (1) 15-shape probe: 15/15 AGREE, zero DIVERGE

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
dup_ids: planner=:ok executor=:executable => AGREE_EXEC
diamond_mixed: planner={:unprovided_need, [m: :rxx]} executor={:not_executable, [:m, :t]} => AGREE_UNPROVIDED
late_provider: planner=:ok executor=:executable => AGREE_EXEC
T1: 15/15 AGREE; DIVERGE count=0 []
```

The residual BK-FONDV-1 shape `dup_ids` (two steps both `id: :a`, no needs,
no provides) now reads `planner=:ok executor=:executable => AGREE_EXEC` —
BK-DUPID's `lists:usort` dedup in assert_acyclic/1
(lib/smalt/pipeline/smalt_fond_plan.erl:47) holds on an independent build.
The probe's divergence counter is a struct in this lane: `DIVERGE count=0`
(no probe-side comprehension quirk to disclose). Probe run twice on the
fresh build root; all 15 shape lines AGREE in both runs.

## (2) Both refusal directions intact, typed, real run/1

```
unprovided_need guard (witness shape) => {:returned, {:crash, {{:unprovided_need, [b: :never_provided]}, [smalt_fond_plan:assert_acyclic/1, line 81, ...]}}}
unprovided_need guard (mid-chain ghost) => {:returned, {:crash, {{:unprovided_need, [b: :ghost]}, [assert_acyclic/1, line 81, ...]}}}
unprovided_need guard (self-need) => {:returned, {:crash, {{:cyclic_plan, [:s]}, [smalt_fond_plan:kahn/5, line 107, ...]}}}
cyclic_plan guard => {:returned, {:crash, {{:cyclic_plan, [:a, :b]}, [smalt_fond_plan:kahn/5, line 107, ...]}}}
```

No accept-direction hole: truly unprovided needs refuse typed pre-execution
(assert_acyclic:81), real cycles refuse as cyclic_plan (kahn:107). The
dup-id dedup does not mask genuine cycles — the `cycle` shape (real a↔b
cycle, no dups) still refuses, and the court's `dup_ids_cycle_control` leg
pins a real cycle beside dup ids refusing `{:refused, :cyclic_plan}`.

## (3) "mirrors exactly" comment — court-backed, witnessed

needs_sat/3's doc (lib/smalt/pipeline/smalt_fond_plan.erl:84-90) claims the
equivalence "pinned by the 15-shape F1-A court (fond_powl_runner_court_test.exs)
against real run/1 executor probes". Verified on disk:

- test/pipeline/fond_powl_runner_court_test.exs:326/330/334 pins
  `dup_ids: :executable`, `dup_ids_exact: :executable` (real run/1), and
  `dup_ids_cycle_control: {:refused, :cyclic_plan}` (dedup must not mask a
  real cycle) — the exact equivalence the comment claims, in a court that
  exits 1 on regression.
- The BK-FONDV counterexample (Kahn's `length(Ids)` counting duplicates
  against an id-keyed Done set) no longer exists: `Ids` is deduped at
  line 47 with the BK-DUPID comment naming this receipt chain.

The comment is now witnessed, not prose.

## (4) Fresh court legs (this lane's build root)

```
MIX_BUILD_ROOT=_build-bkfondw mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
  → Result: 31 passed
MIX_BUILD_ROOT=_build-bkfondw mix test test/internal/expl10r_court_test.exs --include expl10r_f1a
  → Result: 15 passed
```

## Verdict

ALIVE. BK-FONDV-1 confirmed closed on an independent build: 15/15 probe
agreement (zero DIVERGE, structurally counted), both refusal directions
typed and pre-execution, the "mirrors exactly" equivalence court-backed at
fond_powl_runner_court_test.exs:326-334, and both suites green fresh
(31 + 15 passed). F1-A stands as closed; the prior wrong claim class
(BK-FONDSD) does not recur here — the fix is in the code, witnessed by two
independent probes on two build roots.

## Falsifiers (standing)

- Any DIVERGE in the 15-shape probe re-opens BK-FONDV-1.
- `dup_ids` / `dup_ids_exact` flipping away from :executable, or
  `dup_ids_cycle_control` / the `cycle` shape admitting, re-opens — dedup
  must never mask a real cycle.
- Any of the four refusal legs returning `{:ok, _}` re-opens the
  accept-direction question.
- The 31 fond-court legs and 15 expl10r_f1a legs are regression guards.
