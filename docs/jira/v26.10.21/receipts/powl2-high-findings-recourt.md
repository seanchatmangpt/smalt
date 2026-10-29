# POWLSK2 — HIGH-1/HIGH-2 re-court against the landed POWL-4 compiler

Date: 2026-10-21. Lane: POWLSK2 (skeptic re-court). Files owned: `test/internal/powl2_nonseparable_court.exs` (new) + this receipt.
Subject: `lib/smalt/powl2/compiler.ex` (md5 7c04d99bc0c21e5c8c7b1768959d96bc), `lib/smalt/powl2.ex`.
Context: solo.
**Standing:** PASS

## Claim under re-court

HIGH-1/HIGH-2 of `docs/jira/v26.10.20/receipts/powl2-wave-skeptic.md` were filed
against an ancestor compiler. The landed POWL-4 compiler claims typed refusals.
Re-craft BOTH skeptic nets exactly and run against the CURRENT
`Smalt.Powl2.Compiler.compile/2`, 5x each.

## Constructions (exactly as re-crafted)

- **HIGH-1 non-separable cross-cut**: places `{source, pa, pb, pj, sink}`;
  transitions `{tf, t1, t2, t3}`; arcs `source->tf, tf->pa, tf->pb, pa->t1,
  pa->t2, t1->pj, t2->pj, pj->sink, pb->t3, t3->sink`. Structure: t3 CONCURRENT
  with both t1 and t2 (`:co`), t1/t2 CONFLICT. `wf_net? => true`.
- **HIGH-2 well-formed loop**: places `{source, i, m, sink}`; transitions
  `{t0, a, b}`; arcs `source->t0, t0->i, i->a, a->m, m->b, b->sink, b->i`
  (loop-back arc `b->i`, so a->b->a is truly possible). `wf_net? => true`.

Construction disclosure: the ancestor skeptic's literal HIGH-2 net
(`source->a->pb->b->sink, b->pl->a`) DEADLOCKS at the initial marking (`a`
requires both `source` and `pl` marked; `pl` is unreachable from `source`), so
its empty-edge ChoiceGraph was the correct compile of a non-sound net. The
re-crafted net above is genuinely well-formed (the task spec: "a->b->a
possible"), and is the net this re-court pins.

## Outputs

Standalone probe (`elixir /tmp/powlsk2_final.exs`, in-memory `Code.compile_file`
of `lib/smalt/powl2.ex` + `lib/smalt/powl2/compiler.ex` — Chicago: real
compiler, real net structs, no mocks):

```
non_separable: wf=true
  relations: %{{:t1, :t2} => :conflict, {:t1, :t3} => :co, {:t1, :tf} => :gt,
               {:t2, :t1} => :conflict, {:t2, :t3} => :co, {:t2, :tf} => :gt,
               {:t3, :t1} => :co, {:t3, :t2} => :co, {:t3, :tf} => :gt,
               {:tf, :t1} => :lt, {:tf, :t2} => :lt, {:tf, :t3} => :lt}
    :refused_non_separable   (x5, all identical)
  all_same=true
  verdict: HOLD
loop: wf=true
  relations: %{{:a, :b} => :co, {:a, :t0} => :gt, {:b, :a} => :co,
               {:b, :t0} => :gt, {:t0, :a} => :lt, {:t0, :b} => :lt}
    {:choice_graph, children: [%ChoiceGraph{children: [a, b],
        edges: [{0, 1}, {1, 0}]}, t0], edges: [{1, 0}]}   (x5, all identical)
  all_same=true
```

Authentic gate output (`MIX_BUILD_ROOT=_build-powlsk2 mix test test/internal/powl2_nonseparable_court.exs`):

```
...
Finished in 0.04 seconds (0.00s async, 0.04s sync)
3 tests, 0 failures
```

Witnesses pinned by the court file (`test/internal/powl2_nonseparable_court.exs`):

1. HIGH-1: `compile(non_separable_net, [])` 5x ->
   `{:error, :non_separable_fallthrough}` every time.
2. HIGH-2: `relations` classifies {a,b} as `:co` both directions;
   `compile(loop_net, [])` 5x -> `{:ok, ChoiceGraph{children: [inner, t0],
   edges: [{1, 0}]}}` where `inner = ChoiceGraph{children: [a, b], edges:
   MapSet.new([{0, 1}, {1, 0}])}` — the loop face IS present (bidirectional
   can-follow), never empty.
3. Non-vacuity (fence against a vacuous loop-face assert): a pure-choice net
   (`source->{a,b}->sink`) compiles to a flat CG with `edges` size 0 — the
   loop-face assertion cannot pass on a choice net.

## Verdicts

- **HIGH-1: CLOSED-WITH-RECEIPT (HOLD).** The landed compiler typed-refuses the
  non-separable class. The ancestor refusal court now holds; the concurrency-
  hiding gate (`concurrency_hiding?/3`) catches the between-blocks co-face the
  ancestor emitted as a mis-modeled loop.
- **HIGH-2: CLOSED-WITH-RECEIPT (HOLD)** — with a construction correction: the
  original HIGH-2 net was a deadlocked (non-sound) net whose empty-edge CG was
  the faithful compile of its own (dead) reachability; re-crafted well-formed
  loop emits the bidirectional loop face exactly as the paper's loop court
  wants. **Register untouched** (court is the witness; no KD row minted).

## Notes for the next auditor

- The relations matrix for the loop net is `:co` both directions and the loop
  face is carried INSIDE the {a,b} block, not at the top-level CG edge set —
  an auditor who checks only the top-level edges (as this lane first did)
  will see `[{1, 0}]` and mis-read it as HIGH-2 regressed. The loop face is a
  property of the {a,b} block's edge set.
- Transient shared-checkout compile freezes from OTHER lanes' in-flight edits
  (`lib/smalt/data_plane/cosmos.ex`, `lib/smalt/egress_router.ex`) were ridden
  out by falling back to standalone `Code.compile_file` probes; this lane did
  not touch those files. All gate runs used `MIX_BUILD_ROOT=_build-powlsk2`.
- Bench law: not a bench lane; no result file written, no machine report.
