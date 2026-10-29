# BK-DUPID — dup-id false-refusal repair (closes BK-FONDV-1)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-DUPID, canonical checkout /Users/sac/smalt,
  MIX_BUILD_ROOT=_build-bkdupid
- **Closes**: BK-FONDV-1 (docs/jira/v26.10.22/receipts/bkfondv-f1a-verify.md:
  dup_ids DIVERGE-PLANNER-REFUSES-EXECUTABLE, 14/15)

## Root cause and fix

Kahn's fixpoint counted `length(Ids)` over the raw id list including
duplicates while the executor's done-set is id-keyed and collapses
duplicates — so `maps:size(Done) =:= length(Ids)` never held for dup-id
plans and they false-refused as `{:cyclic_plan, [dup]}` while `next_ready/2`
executed them. Fix: `Ids = lists:usort(...)` in `assert_acyclic/1`
(lib/smalt/pipeline/smalt_fond_plan.erl, with a BK-DUPID comment) so the
planner's fixpoint is over the same deduped id set the executor sees. The
"mirrors next_ready/2 exactly" comment on needs_sat/3 is now literally true.

## Falsifiers — all run, all pass

### (1) 15-shape probe (BK-FONDV's probe re-run fresh on the fixed tree)

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
T1 DIVERGENCES: 15 [[], ...]  (per-shape lines: zero DIVERGE — probe-side
unflattened-comprehension counter quirk, disclosed in bkfondv receipt)
```

15/15 AGREE; the dup_ids shape flipped DIVERGE → AGREE_EXEC. (Probe:
/tmp/bkdupid_probe.exs, BK-FONDV's /tmp/bkfondv_probe.exs verbatim;
`MIX_BUILD_ROOT=_build-bkdupid mix run --no-start`.)

### (2) Accept-direction intact — all four refusal legs typed, real run/1

```
unprovided_need guard (witness shape) => {:returned, {:crash, {{:unprovided_need, [b: :never_provided]}, [smalt_fond_plan:assert_acyclic/1 ...]}}}
unprovided_need guard (mid-chain ghost) => {:returned, {:crash, {{:unprovided_need, [b: :ghost]}, [assert_acyclic/1 ...]}}}
unprovided_need guard (self-need) => {:returned, {:crash, {{:cyclic_plan, [:s]}, [smalt_fond_plan:kahn/5 ...]}}}
cyclic_plan guard => {:returned, {:crash, {{:cyclic_plan, [:a, :b]}, [smalt_fond_plan:kahn/5 ...]}}}
```

### (3) Fresh court legs (this lane's build root)

```
MIX_BUILD_ROOT=_build-bkdupid mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
  → Result: 31 passed, exit 0
  (29 prior + 2 new BK-DUPID legs: dup_ids_exact → planner AND real run/1
  executor both :executable on two steps both id :a; dup_ids_cycle_control →
  both refuse {:refused, :cyclic_plan} for a real cyc1→cyc2 cycle alongside
  dup ids — dedup does not mask genuine cycles.)
MIX_BUILD_ROOT=_build-bkdupid mix test test/internal/expl10r_court_test.exs --include expl10r_f1a
  → Result: 15 passed, exit 0
```

## Verdict

ALIVE. BK-FONDV-1 closed: dup-id plans reach the same fixpoint the executor
sees; real cycles still refuse typed before execution; 15/15 probe agreement;
accept-direction unhurt. F1-A's "mirrors exactly" comment is now witnessed
rather than prose.

## Falsifiers (standing)

- Any DIVERGE line in the 15-shape probe re-opens this finding.
- `dup_ids_cycle_control` (or the `cycle` shape) passing as :executable
  re-opens — dedup must never mask a real cycle.
- Any of the four refusal legs returning `{:ok, _}` re-opens the
  accept-direction question.
- The 31 fond-court legs and 15 expl10r_f1a legs are regression guards.
