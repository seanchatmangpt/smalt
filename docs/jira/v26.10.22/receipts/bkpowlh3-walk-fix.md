# BK-POWLH3 — executor can-follow closure walk completion (BK-POWLH2-2 close-out)

Standing: ALIVE
Context: solo
Build root: `_build-bkpowlh3`
Date: 2026-10-22
Owner lane: BK-POWLH3

## Verdict

BK-POWLH2-2 is CLOSED in lib/. The executor's ChoiceGraph walk was a single
first-outgoing-edge path: on a sound net with tail `sign -> pub -> join`, the
walk picked `nested -> join` and terminated without ever firing `t_pub`.
`lib/smalt/powl2/eval_choice` now runs a CLOSURE-COMPLETE walk:

- From each node it takes EVERY guard-viable outgoing edge, not just the first:
  exact `last_outcome` guard matches still suppress the fallbacks (choice face
  preserved — the pinned `err_branch must be skipped` / `phi_lease_final == 2`
  legs pass unchanged), otherwise every `:always`/unguarded edge is viable
  (sequential tail — every node the closure orders after the pick fires).
- Each child is evaluated exactly once (shared visited set propagated back from
  sub-walks to sibling branches — a first cut that dropped sub-walk visited
  state produced a re-fire flood and was repaired in-lane before landing).
- Cycle edges (loop face: the bidirectional can-follow cas<->retry pair) are
  exempt from visited-once: re-entry is guard-driven and bounded by
  `@walk_reentry_budget 256` — a degenerate `:always` cycle fails closed with a
  new typed error `{:choice_walk_reentry_budget_exceeded, node}` instead of
  spinning.
- The old typed refusal `{no_outgoing_edge_matches, from, last}` is preserved
  when a non-terminal node has no guard-viable outgoing edge.
- The compiled Powl2.ChoiceGraph start/end short-circuit (nil/nil -> immediate
  return, children never fire outside a tau-delimited projection) is unchanged.

## Embedded probe (witnessed shape, _build-bkpowlh3, mix run --no-start)

Sound net, tail `sign -> pub -> join` (publish BEFORE the join — the exact
shape the old walk skipped):

```
compile: OK
CG edges=[{0, 2}, {0, 3}, {1, 0}, {1, 2}, {1, 2}...]
  [0] nested(cas/retry/sign)
  [1] T:t_in
  [2] T:t_join
  [3] T:t_pub
fired (pre-fix):  [:t_cas, :t_sign, :tau, :t_join, :tau]      # t_pub never fired
fired (post-fix): [:t_cas, :t_sign, :tau, :t_join, :tau, :t_pub, :t_in]
t_pub fired? true
```

`t_pub` fires exactly once; each ordered child fires exactly once; the loop
face keeps guard-driven iteration. (t_in now also fires — same skip class,
never fired under the old walk; nothing pinned its absence.)

## Court output (embedded, _build-bkpowlh3)

```
MIX_BUILD_ROOT=_build-bkpowlh3 mix test test/internal/powl2_executor_test.exs \
  test/internal/powl2_nonseparable_court.exs test/internal/powl2_compiler_test.exs \
  test/internal/powl2_reticle_test.exs test/internal/powl2_projection_test.exs \
  test/internal/powl2_andon_wire_court.exs test/internal/powl2_law_guard_court.exs \
  test/internal/expl10r_court_test.exs test/integration/powl2_gates_court.exs \
  test/pipeline/fond_powl_runner_court_test.exs test/integration/graphlaw_powl_business_net.exs \
  test/integration/graphlaw_skeptic_court.exs test/integration/graphlaw_fullstack_court.exs \
  test/integration/graphlaw_rule_change.exs test/integration/ath3_law_court_test.exs \
  test/integration/gld7_ingest_to_settlement_court_test.exs
Result: 162 passed
```

Includes the NEW court leg (test/internal/powl2_executor_test.exs, "BK-POWLH3:
can-follow closure walk fires the witnessed sequential tail"): real Compiler on
the witnessed sound net, court-side tau-delimited projection, real executor
run; asserts t_pub/t_join/t_sign each fire exactly once AND the loop face
(cas twice with outcomes [:cas_conflict, :cas_ok], retry once).

Executor unit legs (choice-face exact-guard skip, :always fallback, phi counts,
andon, law guard, F1-A) all stay green: 43 passed on the internal battery
before the integration set was added.

## Typed findings

- **BK-POWLH3-1 (pre-existing, not this lane's surface):** the batched
  integration run earlier in the lane failed 5 legs of
  `test/internal/internal_tier_census_test.exs` — all five name
  `bkmon3r_deadjoin_court_test.exs` (BK-MON3R's unregistered in-flight court
  file: population drift, status-literal asserts, ARM literals, off-allowlist
  module refs, forbidden client tokens). Pre-existing other-lane debt, zero
  relation to executor.ex; without that file in the batch the same courts run
  162/162. Census owner should register or the MON3R owner should land.
- **BK-POWLH3-2 (noted, not repaired):** firing t_in from the walk (leg
  1) is new behavior: the OLD walk also skipped t_in on this shape. No court
  pinned its absence; the closure says it is ordered, so firing it is the
  faithful reading. Flagged so downstream courts that observe executor step
  sets are re-checked against closure-complete semantics.
- **BK-POWLH3-3:** `:tau` steps: the tau-delimited projection's entry tau is
  still never evaluated (walk starts AT start without evaluating it) —
  preserved from the old walk; the exit tau fires (also preserved: the old
  walk evaluated the end child before the cur==end base case).

## Files changed

- `lib/smalt/powl2/executor.ex` — closure-complete ChoiceGraph walk (visited
  set, cycle-edge re-entry with budget, exact-guard choice suppression),
  `pick/4` replaced by `pick_all/4` + `cycle_edges/1`; dead `pick/4` removed.
- `test/internal/powl2_executor_test.exs` — new court leg + court-side
  tau-delimited SESE projection helpers (witnessed_projection/witness_child).

## Repro commands

```
MIX_BUILD_ROOT=_build-bkpowlh3 mix test test/internal/powl2_executor_test.exs
MIX_BUILD_ROOT=_build-bkpowlh3 mix test test/internal/powl2_executor_test.exs \
  test/internal/powl2_nonseparable_court.exs test/internal/powl2_compiler_test.exs \
  test/integration/powl2_gates_court.exs test/pipeline/fond_powl_runner_court_test.exs
```
