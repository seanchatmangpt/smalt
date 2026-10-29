# BK-FONDSKEP — FOND runner adversarial skeptic audit (EXPL10-R repairs)

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-FONDSKEP, canonical checkout /Users/sac/smalt, MIX_BUILD_ROOT=_build-bkfondskep (left for coordinator `just lane-clean`)
- **Audits**: docs/jira/v26.10.22/receipts/expl10r-high-repairs.md (F1/F2/F3), docs/jira/v26.10.22/receipts/bk4-fondrunner.md

## Verdict per target

1. **Unprovided-need refusal (F1 witnessed shape + variants): PASS.** Three
   shapes (witnessed `need=:never_provided`, mid-chain ghost need,
   self-need) all return
   `{:crash, {{:unprovided_need, [{step, need}]}, [assert_acyclic/1 stack]}}`
   from `run/1` — typed, before any execution, no partial seal.
2. **needs_sat/3 ≡ next_ready/2 equivalence: FALSIFIED — HIGH (F1-A).**
   15-shape property probe (linear/diamond/fork/join/mixed-provides/
   unprovided/cycle/self-need/dup-provider×2/empty/done-id-only/dup-ids/
   diamond-mixed/late-provider): **5/15 shapes diverge**, all in the
   false-REFUSAL direction (planner refuses plans the executor runs to
   completion — the dangerous accept-direction divergence is closed, 0/15):
   - `join` (needs are bare step ids with no `provides` anywhere):
     planner `{:unprovided_need, [j: :j1, j: :j2]}` vs executor
     `:executable` (needs_sat/2's done-id arm satisfies them at runtime;
     the planner's `Unprovided` precheck ignores the done-id arm).
   - `done_id_only`, `dup_ids`: same done-id-arm class.
   - `dup_provider` / `dup_provider_min` (two steps provide `:x`, second
     needs `:x`): planner `{:cyclic_plan, [:b]}` vs executor `:executable`
     — the `Providing` map is last-wins (`maps:from_list` collapse), while
     next_ready/2 accepts any done provider.
   The repair's claim "needs_sat/3 mirrors next_ready/2 exactly"
   (smalt_fond_plan.erl:64-66 comment) is not true as landed. Repair
   prescription: make the `Unprovided` precheck and `Providing` accept the
   same satisfaction law as next_ready/2 — a need is provisionally
   satisfiable iff `lists:member(N, Ids) orelse maps:is_key(N, Providing)`
   (done-id arm) and provider lookup must tolerate multiple providers
   (e.g. `Providing: term -> [id]`), then re-check fixpoint. All observed
   refusals were typed and safe (over-refusal, availability regression —
   but `join` is a natural hand-built shape, so this will bite real
   callers).
3. **run_op unknown-shape refusal (F3): PASS.** Through the real
   `Smalt.POWL2.Executor.execute_admitted/6` (real admission, real
   Transition AST, no mocks): `{:error,:throttled,:retry_after_5}` →
   `{:error, {:transition_failed, :t1, {:error, :throttled, :retry_after_5}}}`
   + `{:orchestration_failed, ...}`; bare atom →
   `{:bad_op_result, :weird}`; 4-tuple `{:ok,ctx,:o,:extra}` →
   `{:bad_op_result, ...}`; `{:ok_outcome, :fine}` → completed with
   `last_outcome: :fine`. Enumerated shapes hold.
4. **F6 residual (run/1 unbounded receive): CONFIRMED HANGABLE — HIGH
   (F6-A), DoS typed.** With a caller-supplied contingency fun that never
   returns (`fun L() -> L() end`), `run/1` never returns: bounded probe
   `{:HUNG, 4000}` while 24 sibling concurrent happy-path runs in the same
   VM returned in 2–42 ms. DoS class: caller-supplied fun occupies the
   gen_statem forever; run/1's receive has no `after`. Prescription:
   (a) `run/1` bounded receive
   `after Timeout -> erlang:demonitor(M, [flush]), {crash, runner_deadline_exceeded}`
   (timeout plumbed via Opts, default e.g. 30s); and/or (b) execute the
   contingency inside the FSM under an Erlang host-mode timeout —
   `gen_statem` event handler... simpler: wrap `Cont(Step)` in a spawned
   worker + bounded receive inside the FSM, so a non-returning contingency
   crashes the FSM typed ({:bad_contingency_timeout, StepId}) instead of
   parking it.
5. **Fresh courts.** Fond court
   (`test/pipeline/fond_powl_runner_court_test.exs --include
   fondrunner_skeptic`): **failed 1/10 on first run, passed 10/10 on two
   consecutive reruns** (embedded below). EXPL10-R court suite (expl10r +
   fond + powl2 executor/andon/law-guard): **46/47, same single leg**
   (S3). Direct evidence says load-flake, not code defect: an 8×3
   concurrent direct `run/1` probe returned 24/24 in 2–42 ms while the
   court failed at load average 83–124 (concurrent lanes compiling on the
   shared tree). **MEDIUM (F6-B, court robustness)**: S3's
   `assert_receive ..., 10_000` is a fixed wall-clock fence over a
   scheduling-dependent observable — load-bound exactly as the no-sleep
   doctrine's ratio-fence law warns; bounded-poll or min-of-N form would
   not flake at load 124. Not classified a re-opened F6: no hang mechanism
   exists for the happy path (no caller fun), and 24/24 direct runs
   returned.

## Court output (embedded, verbatim tails)

Fond court rerun 1 and 2 (after the load-flake failure):

```
run1 EXIT=0  (10/10 passed)
run2 EXIT=0  (10/10 passed)
```

EXPL10-R court suite:

```
Finished in 10.9 seconds (0.00s async, 10.9s sync)
Result: 46/47 passed
Failed: 1 test   <- S3 (load-flake; passes 10/10 standalone twice)
```

T1 equivalence probe (15 shapes, real assert_acyclic vs real next_ready
fixpoint simulation):

```
linear: AGREE_EXEC
diamond: AGREE_EXEC
fork: AGREE_EXEC
join: planner={:unprovided_need, [j: :j1, j: :j2]} executor=:executable => DIVERGE-PLANNER-REFUSES-EXECUTABLE
mixed_provides: AGREE_EXEC
unprovided: AGREE_UNPROVIDED
cycle: AGREE_CYCLE
self_need: AGREE_UNPROVIDED
dup_provider: planner={:cyclic_plan, [:b, :c]} executor=:executable => DIVERGE-PLANNER-REFUSES-EXECUTABLE
dup_provider_min: planner={:cyclic_plan, [:b]} executor=:executable => DIVERGE-PLANNER-REFUSES-EXECUTABLE
empty: AGREE_EXEC
done_id_only: planner={:unprovided_need, [b: :a]} executor=:executable => DIVERGE-PLANNER-REFUSES-EXECUTABLE
dup_ids: planner={:cyclic_plan, [:a]} executor=:executable => DIVERGE-PLANNER-REFUSES-EXECUTABLE
diamond_mixed: AGREE_UNPROVIDED
late_provider: AGREE_EXEC
T1 DIVERGENCES: 0 []   <- counter undercount (comprehension scoping bug in the probe itself); the per-shape lines above are the evidence: 5 DIVERGE lines
```

T2 run/1 refusal shapes (real gen_statem crashes, trimmed):

```
witness (need :never_provided) => {:returned, {:crash, {{:unprovided_need, [b: :never_provided]}, [smalt_fond_plan:assert_acyclic/1, ...]}}}
variant mid-chain ghost need => {:returned, {:crash, {{:unprovided_need, [b: :ghost]}, [...]}}}
variant self-need => {:returned, {:crash, {{:unprovided_need, [s: :s]}, [...]}}}
```

T2b F6 hang probe:

```
F6 non-returning contingency fun => {:HUNG, 4000}
```

T3 real-executor run_op shapes:

```
op 3-tuple error {:error,:throttled,:retry_after_5} => {:error, {:transition_failed, :t1, {:error, :throttled, :retry_after_5}}} msgs=[{:orchestration_failed, :probe, {:transition_failed, :t1, {:error, :throttled, :retry_after_5}}}]
op bare atom :weird => {:error, {:transition_failed, :t1, {:bad_op_result, :weird}}} msgs=[{:orchestration_failed, :probe, {:transition_failed, :t1, {:bad_op_result, :weird}}}]
op 4-tuple {:ok,:x,:y,:z} => {:error, {:transition_failed, :t1, {:bad_op_result, {:ok, %{}, :o, :extra}}}} msgs=[...]
op ok_outcome => :ok msgs=[{:orchestration_completed, :probe, %{last_outcome: :fine}, %{id: :probe, status: :completed, steps: [%{node: :t1, kind: :transition, outcome: :fine}], phi_lease_final: 1}}]
```

## Disclosures

- The probe's own divergence counter undercounted (0 vs the 5 DIVERGE
  lines): `divs` rebinds locally inside an Elixir `for` comprehension.
  The per-shape lines are the evidence; the counter line is quoted as
  emitted, not corrected.
- First full-court run failed S3 at load average 124 (8 concurrent lanes
  compiling); classified load-flake on direct-probe evidence, not a
  runner defect. Machine was never quiet this session; `just quiet-check`
  discipline could not be satisfied.
- T3's first attempt was refused at real admission
  (`{:shacl_violation, "transition missing label"}` — the probe's
  Transition lacked `label`); probe fixed to carry `label: "probe"`.
  Admission itself behaved correctly (typed refusal before op).
- Probe scripts: /tmp/bkfondskep_probe.exs, /tmp/bkfondskep_s3.exs;
  logs /tmp/bkfondskep_*.log. No lib/ or test/ files touched.

## Falsifiers (standing checks)

- Any `{:ok, receipt}` or seal from a plan with an unprovided need
  re-opens F1.
- A join/done-id/dup-provider shape admitted by `assert_acyclic/1` with
  the current check, or needs_sat fixed and a shape flips to AGREE,
  re-opens/advances F1-A.
- A non-returning contingency fun that returns `{:crash, _}` (bounded)
  instead of hanging `run/1` closes F6-A.
- S3 passing 3/3 on a quiet machine (load < 10) or after converting to a
  bounded poll closes F6-B.
