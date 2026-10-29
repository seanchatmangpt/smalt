# BK-POWLV — POWL2 HIGH-2 loop-compile verify lane (read-only)

Standing: **ALIVE** — Context: solo

Lane: BK-POWLV. Wait-bounded on BK-POWLH2; its receipt
`bkpowlh2-loop-compile.md` never landed, but the HIGH-2 fix itself IS on the
tree, landed via tick checkpoint 477d88c5 (compiler.ex +40: `soundness_gate/2`,
`:net_not_sound` refusal, sink-reachability + dead-transition check; court legs
in `test/internal/powl2_nonseparable_court.exs`). Verified on disk at
`lib/smalt/powl2/compiler.ex` (HEAD c9627022 + no dirty compiler.ex — tree
status shows compiler.ex clean).

## 1. wf loop-net probe (fresh, own build root `_build-bkpowlv`)

Command:
`MIX_BUILD_ROOT=_build-bkpowlv mix run --no-start tmp/bkpowlv_probe.exs`
(probe kept in-repo at `tmp/bkpowlv_probe.exs`, in-memory, no substrate)

```
LEG1 HIGH-2 unsound minimal wf loop net (source->a->pb->b->sink, b->pl->a)
  wf_net? = true
  compile => {:error, :net_not_sound}
  edge-less ChoiceGraph unrefused? false (must be false)
```

The witnessed edge-less ChoiceGraph shape is GONE. The unsound "loop" net is
typed-refused `:net_not_sound` while `wf_net?` still admits its shape — the
gate does real work over the shape gate.

## 2. Sound loop face preserved

```
LEG1b sound loop net (source->t0->i; i->a->m->b; b->sink, b->i)
  compile => {:ok, %ChoiceGraph{children: [%ChoiceGraph{children: [a, b],
    edges: MapSet.new([{0,1},{1,0}])}, t0]}, edges: [{1,0}]}}
  loop face present (edges non-empty)? true
```

A genuinely sound loop still compiles WITH its bidirectional can-follow loop
face — the fix refuses unsound nets without breaking loop representation.

## 3. Court legs re-run fresh (embedded output)

```
LEG2  reticle PO 2-cycle  => {:error, {:shacl_violation, "cycle in partial order through :a"}}
LEG2  reticle PO 3-cycle  => {:error, {:shacl_violation, "cycle in partial order through :c"}}
```

## 4. Adversarial legs

```
LEG2b reticle CG trapped-child => {:error, {:shacl_violation, "trapped child :trap: not on any start→end path"}}
LEG3a nested-cycle loop net (outer loop b->i, inner cycle a<->c)
  wf_net? = true
  compile => {:error, :net_not_sound}
LEG3b self-loop-only net (source->a->sink, a->pa->a)
  wf_net? = true
  compile => {:error, :net_not_sound}
```

- LEG3a/LEG3b: both nets are GENUINELY UNSOUND (inner cycle makes `a` require
  `p2` marked by `c`, reachable only via `a` itself; self-loop makes `a`
  require `pa` produced only by `a`), so `:net_not_sound` is the CORRECT
  typed verdict, not a false positive of the gate.
- LEG3c loop-body dead-end: compiles `:ok` with the correct loop shape. My
  leg-3c net (`i->a; a->pd & a->sink; pd->b; b->sink, b->i`) is not 1-safe
  (`a` can deposit a second `sink` token on the second iteration), so this
  pins a GATE-SCOPE BOUNDARY: the soundness gate checks sink-reachability and
  dead transitions but not 1-safeness — the documented precondition still
  carries safeness ("SAFE SOUND WF-net") as prose. Honest typing: compiles
  correctly for its shape; safeness remains an unenforced precondition.
- Reticle legs show the BK-REWIT3 "2-cycle admits" drift is CLOSED on the
  current tree: both cycles now typed-refuse, matching the new court legs
  ("reticle cycle pin" test).

## 5. Suites fresh (one run, `_build-bkpowlv`)

```
Finished in 2.8 seconds (2.1s async, 0.7s sync)
Result: 195 passed
```

powl2 (13 files incl. nonseparable court, reticle, compiler, decomposition,
primitives, executor, projection, change_feed, graph_compat, law_compiler,
law_guard, andon, andon_wire) + `test/pipeline/fond_powl_runner_court_test.exs`
+ 3 graphlaw integration courts (powl_business_net, fullstack, skeptic).
0 failures. The executor `law_guard` error trace in the output is an
expected error-injection leg, not a failure.

## Verdict

ALIVE: the HIGH-2 mis-compile is closed on the current tree — edge-less
ChoiceGraph for unsound loop nets is replaced by the typed
`:net_not_sound` refusal; sound loops keep their loop face; cycles,
trapped children, and unsound nested/self-loop nets are typed-refused; the
1-safeness gap is pinned as a documented gate-scope boundary, not a silent
one.

## Build root

`_build-bkpowlv` (lane root, left for coordinator `just lane-clean`).
