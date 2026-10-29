# BK-FONDSD — FONDSKEP repair lane (F1-A + F6-B)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-FONDSD, canonical checkout /Users/sac/smalt,
  MIX_BUILD_ROOT=_build-bkfondsd (left for coordinator `just lane-clean`)
- **Audits**: docs/jira/v26.10.22/receipts/bkfondskep-runner-audit.md (F1-A HIGH,
  F6-B MEDIUM). F6-A (run/1 unbounded receive) skipped — BK-F6R owns the
  receive bound (its receipt bkf6r-receive-bound.md was not on disk this
  session; not double-touched).

## F1-A — planner/executor satisfiability divergence (HIGH) → CLOSED

Root cause, both in `lib/smalt/pipeline/smalt_fond_plan.erl`:

1. The `Unprovided` precheck in assert_acyclic/1 ignored next_ready/2's
   done-id arm: a need that IS another step's id is satisfied at execution
   time when that step completes, even with no `provides` anywhere. The old
   precheck refused join / done-id-only / dup-ids shapes as
   `unprovided_need` while the executor ran them to completion.
2. `Providing` was a last-wins single-provider map
   (`maps:from_list` collapse). next_ready/2 accepts ANY done provider, so
   two steps providing the same term made the planner falsely report
   `cyclic_plan` while the executor executed.

Repairs (smalt_fond_plan.erl):

- `Providing` rebuilt as `term() -> [id()]` via a fold of
  `maps:update_with/4` — multiple providers of one term accumulate instead
  of collapsing.
- `Unprovided` precheck now reads
  `not lists:member(N, Ids) andalso not maps:is_key(N, Providing)` —
  the done-id arm of the executor's law.
- `needs_sat/3` provider arm updated to the list form
  (`lists:any` over done-ness of provider ids); its done-key arm and the
  Kahn fixpoint are unchanged.

BEFORE evidence: the FONDSKEP audit's 15-shape probe (5 DIVERGE lines,
all planner-refuses-executable: join, done_id_only, dup_provider,
dup_provider_min, dup_ids) — quoted in the audit receipt, not re-run
(this lane's falsifier legs pin the AFTER, and the accept-direction
divergence was already 0/15 pre-repair, so nothing could regress to
unsafe-accept).

AFTER court legs (test/internal/expl10r_court_test.exs, new
`F1-A planner/executor satisfiability agreement` describe, tag
`:expl10r_f1a`, all `@describetag`, real `run/1` real seal — no mocks):

```
join shape (needs are bare step ids, no provides) now runs to completion → {:ok, r}, step_count == 3
done-id-only chain runs → {:ok, r}, step_count == 2
duplicate providers of one term no longer false-refuse as cyclic_plan → {:ok, r}, step_count == 3
truly unprovided need still refuses typed → {:crash, {{:unprovided_need, [{:b, :never_provided}]}, _stk}}
real cycle still refuses as cyclic_plan → {:crash, {{:cyclic_plan, remaining}, _stk}}, remaining sorted == [:a, :b]
```

Full suites, this lane's build root:

```
MIX_BUILD_ROOT=_build-bkfondsd mix test test/internal/expl10r_court_test.exs --include expl10r_f1a
  → 15 passed (10 pre-existing + 5 F1-A legs)
MIX_BUILD_ROOT=_build-bkfondsd mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
  → 13 passed
```

## F6-B — S3 fixed fence (MEDIUM) → CLOSED

`test/pipeline/fond_powl_runner_court_test.exs` S3: the single fixed
`assert_receive {^ref, {:ok, r}}, 10_000` fence (the load-flake FONDSKEP
witnessed at load 124) is replaced by a bounded poll:
`recv_until_ok/2` receives in 250 ms slices against a 30 s monotonic
deadline and fails typed on exhaustion — convergence-within-budget, not a
one-shot wall-clock guess. Structural sync (ref-tagged messages) unchanged.

Fond court with the new S3 form: 13/13 passed (embedded above).

## Not-touched / disclosures

- The census suite (test/internal/internal_tier_census_test.exs) currently
  fails 2 legs on `expl11r3_court_test.exs` drift (on-disk but unregistered;
  forbidden Jason tokens) — EXPL11-R3's in-flight file, NOT this lane's
  drift; my edits are inside the registered expl10r file. Also witnessed a
  transient compile-freeze on another lane's `lib/smalt/egress_router.ex`
  (BK-EGS1 mid-edit at 06:22; TokenMissingError, resolved on rerun after
  their edit settled). Both are other-owner failures, disclosed typed.
- Probe scripts: none minted this lane; the FONDSKEP probes
  (/tmp/bkfondskep_probe.exs) serve as the BEFORE record and the court legs
  as the AFTER.
- `lib/smalt/pipeline/smalt_fond_powl_runner.erl` untouched (F6-A is F6R's).

## Falsifiers

- Any of the 5 new F1-A legs failing, or a new planner-refuses-executable
  shape, re-opens F1-A.
- S3 failing twice consecutively on a quiet machine (load < 10) re-opens
  F6-B.
- The 10 pre-existing EXPL10-R legs and 12 other fond-court legs are
  regression guards: any failure re-opens this lane's standing.
