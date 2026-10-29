# BK-POWLH2 — powl2 loop compile (BK-REWIT3 HIGH-2) close-out

Standing: PARTIAL_ALIVE (fix landed and courted on this lane's build root; full-court /
cross-SDK census not run)
Context: solo
Build root: `_build-powlh2`
Date: 2026-10-22

## Verdict

HIGH-2 is closed with a typed disposition, not a loop-back-edge patch: the receipt's
minimal "loop" net (`source->a->pb->b->sink`, `b->pl->a`) is **unsound**, not a
mis-compiled loop. `a` has two input places (`source`, `pl`); Petri-net enabling
requires both marked, `source` is consumed up-front, so `a` can never fire, the
sink is unreachable, and BOTH transitions are dead. Dead transitions classify
`:conflict`, and the edge-less ChoiceGraph was the "faithful" compile of dead
behavior. The real defect was that the compiler's "safe sound WF-net" precondition
was prose only. Repair: `Smalt.Powl2.Compiler.compile/2` now machine-checks
soundness — sink reachable from the source plus every transition enabled somewhere
— and refuses with the new typed error `:net_not_sound` (added to `compile_err/0`).
Sound loops still compile WITH their loop face (the existing court leg pins the
bidirectional can-follow pair; unchanged).

Reticle drift pin: the wave-3 claim "2-cycle now :ok, 3-cycle refuses" does NOT
reproduce on the current tree — the transitive-closure cycle check refuses BOTH
(typed `{:error, {:shacl_violation, "cycle in partial order through ..."}}`). New
court legs pin both refusals; the hole is closed on the current behavior.

## Embedded probe (reproduction, _build-powlh2, mix run --no-start)

```
wf_net? true
rels: {a,b}=:conflict {b,a}=:conflict
loop_pair?(a,b): false
flow a->b: true  b->a: true
compile => {:ok, ChoiceGraph{children: [a, b], edges=[]}}   # pre-fix
# post-fix:
{:error, :net_not_sound}
```

Note `wf_net?/1` admits the net (shape-gate only) — the new gate does real work.

## Court output (embedded)

```
mix test test/internal/powl2_nonseparable_court.exs ... (12 powl2 internal files)
Result: 105 passed

mix test test/integration/powl2_gates_court.exs
Result: 5 passed

mix test test/pipeline/fond_powl_runner_court_test.exs
Result: 31 passed

graphlaw_powl_business_net 5 passed; graphlaw_skeptic_court 29 passed;
graphlaw_fullstack_court 2 passed; graphlaw_rule_change 4 passed;
ath3_law_court PASS; gld7_ingest_to_settlement_court PASS
```

## Typed findings

**BK-POWLH2-1 (premise rot, repaired in-court):** the POWL-10 "settlement net"
(`test/integration/powl2_gates_court.exs`) was itself UNSOUND — t_sign and t_pub
both consumed the single p2 token (choice, not the modeled concurrency), so
t_join ({p3,p4} inputs) starved, the sink was unreachable. The pinned "ONE flat
ChoiceGraph + loop face" POWL-10 divergence was derived from dead-branch behavior.
Repaired to a sound net (loop exits via t_sign; tail t_join -> t_pub -> sink;
places now {src,p1,p2,p3,p5,sink}); the divergence assertion re-derived: the
compile now NESTS the cas/retry/sign loop cluster and the loop face is pinned
inside the nested ChoiceGraph. to_reticle's guard-overlay lookup also crashed on
nested ChoiceGraph children (KeyError :label) — repaired (transition-only match).

**BK-POWLH2-2 (typed finding, open, owner: executor lineage):** the executor's
can-follow ChoiceGraph walk is a single first-outgoing-edge path — it can
terminate having never visited a child the can-follow closure says is ordered
AFTER the picked successor (witnessed: sound net with flow sign->pub->join
compiled to a CG whose walk picked nested->join and never fired t_pub). The
settlement net's tail was reordered (join before pub) so the closure edges cannot
shortcut the walk. NOT FIXED in lib/ — a can-follow closure with a first-edge
walk is not a faithful executor for sequential tails; recommend a topological
walk or closure-aware picking. No court pins this in lib/; the court pins the
reordered net only.

**BK-POWLH2-3 (typed finding, open, owner: graphlaw/integration lineage):** three
integration courts (powl2_gates_court.exs, graphlaw_*.exs, ath3, gld7) do not
match Elixir 1.20's default `test_pattern` (`*_test.exs`) — `mix test <file>`
warns "do not match any of the configured test_load_filters", and batched runs
abort mid-battery (ath3/gld7 self-run and exit the VM at load, so a mixed batch
silently drops every file after them; witnessed: 8-file batch exited 0 after
gld7's PASS with the remaining files unexecuted). The courts pass individually.
Recommend renaming to *_test.exs or seeding a dedicated runner recipe.

## Files changed

- `lib/smalt/powl2/compiler.ex` — soundness gate (sink reachable + no dead
  transitions) with typed `:net_not_sound`; moduledoc updated. NOTE: dispatch
  named `law_compiler.ex` as the owned surface, but the loop compile path lives
  in `compiler.ex` (law_compiler.ex is the SHACL guard compiler, untouched) —
  file-ownership delta disclosed here.
- `test/internal/powl2_nonseparable_court.exs` — HIGH-2 residual leg (unsound
  minimal loop net -> `{:error, :net_not_sound}`, 5x deterministic, with the
  :conflict dead-transition signature pinned); reticle 2-cycle AND 3-cycle
  refusal pins.
- `test/internal/powl2_compiler_test.exs` — pt_handle net repaired to the sound
  PT-handle shape (choice branches re-join via a SHARED post-place p3; the old
  three-input join {p3,p4,p5} could never fire — same unsoundness class as
  HIGH-2).
- `test/integration/powl2_gates_court.exs` — settlement net repaired (BK-POWLH2-1)
  + re-derived loop-face pin + nested-CG-safe guard overlay lookup.

## Repro commands

```
MIX_BUILD_ROOT=_build-powlh2 mix test test/internal/powl2_nonseparable_court.exs \
  test/internal/powl2_compiler_test.exs test/integration/powl2_gates_court.exs
MIX_BUILD_ROOT=_build-powlh2 mix test test/pipeline/fond_powl_runner_court_test.exs
MIX_BUILD_ROOT=_build-powlh2 mix test test/integration/graphlaw_skeptic_court.exs
```
