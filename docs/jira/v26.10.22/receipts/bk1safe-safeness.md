# BK-1SAFE — POWL2 1-safeness boundary typed (disposition: boundary, not gate)

Standing: **ALIVE** (boundary typed and court-pinned) — Context: solo

Lane: BK-1SAFE. Owner files: `lib/smalt/powl2/compiler.ex` (moduledoc only),
`test/internal/powl2_nonseparable_court.exs` (+2 legs), this receipt.
Build root `_build-bk1safe`.

## Disposition

**Boundary typed, not a gate.** 1-safeness is deliberately NOT machine-checked
in `Smalt.Powl2.Compiler`. Reasoning (all three legs witnessed):

1. The compile-time reachability engine is SET-semantics by representation:
   markings are `MapSet`s of place ids (compiler.ex `fire/3` — consume via
   `MapSet.difference`, produce via `MapSet.union`), so a place holding 2+
   tokens is unrepresentable; multiplicity collapses on union.
2. The runtime executor (`Smalt.POWL2.Executor`) is a "pure topology engine
   over the POWL2 AST" — a ChoiceGraph walk keyed on `ctx.last_outcome`, with
   `Task.async` PO frontier concurrency. Token-agnostic: no token game ever
   runs against the compiled model, so a multi-token place cannot break the
   walk.
3. A multiset token-game 1-safeness gate would refuse the canonical redo-loop
   net the HIGH-2 court leg pins as the loop representation
   (`source->t0->i; i->a->m->b; b->sink, b->i`: each loop iteration re-feeds
   the sink place, so under multiset semantics the net is not 1-safe — yet its
   compiled AST carries exactly the bidirectional can-follow loop face the
   AST is defined to express). A multiset gate would flip a sibling lane's
   pinned court verdict with no runtime defect behind it.

So the compile/executor stack is self-consistent under set semantics.
1-safeness remains an input-side precondition, now typed in the moduledoc as
a deliberate boundary (not silent prose): a not-1-safe net is analyzed under
set semantics and compiles consistently with that analysis; consumers wanting
multiset-truth semantics must pre-gate upstream.

## 1. Reproduction (probe `tmp/bk1safe_probe.exs`, fresh, real compiler)

`MIX_BUILD_ROOT=_build-bk1safe mix run --no-start tmp/bk1safe_probe.exs`

```
LEG A  2-unsafe net (a,b -> p -> c)     [choice-shaped variant]
  wf_net? = true
  compile = {:ok, %ChoiceGraph{...}}                       # :ok today — reproduced
LEG B  reachable markings (set semantics):
  [MapSet.new([:p]), MapSet.new([:sink]), MapSet.new([:source])]   # multiplicity collapsed
LEG C  compiled AST + relation matrix — total, no token counts anywhere
```

The true and-split 2-unsafe net (t1, t2 both fireable from `{m}`, both
producing into p) is pinned in the court leg below; it compiles `:ok`
deterministically (5x).

## 2. Court legs (embedded output, `_build-bk1safe`)

`MIX_BUILD_ROOT=_build-bk1safe mix test test/internal/powl2_nonseparable_court.exs`

```
Result: 7 passed
```

Two new legs:

- **BK-1SAFE boundary pin**: the and-split not-1-safe net
  (`source->t0->m; m->{t1,t2}->p; p->t3->sink`) compiles `:ok` 5x
  deterministic; its relation matrix is total over all 12 ordered transition
  pairs (no nil cells, no `:net_not_safe` cap refusal) — the set-semantics
  analysis is well-defined.
- **BK-1SAFE non-vacuity**: mutating the same net (back-edge `p->t0`, t0
  needs `{source, p}` → deadlock, sink unreachable) flips it to
  `{:error, :net_not_sound}` while the un-mutated net still compiles `:ok`.
  The gate distinguishes — `:ok` for the 2-unsafe net is a typed boundary,
  not a vacuous gate that never looks.

## 3. Suites

```
powl2 family (13 internal + fond_powl_runner + 3 graphlaw integration courts):
Result: 200 passed
test/integration/powl2_gates_court.exs standalone: 5 passed
```

Note: running `powl2_gates_court.exs` inside the big-file combo invalidates
5 tests (`setup_all {:already_started}` collision) — a pre-existing combo
artifact, not this lane's diff; the file passes standalone and in the
integration-only run (41 passed). Pre-existing tree warnings (sas_verifier
duplicate clauses, plug/dialyzer noise) are other-lane surfaces, untouched.

## Verdict

ALIVE: the classic 2-token place net compiles `:ok` (reproduced on the real
compiler) and that behavior is now TYPED as a deliberate set-semantics
boundary with court legs pinning both the acceptance and the gate's
non-vacuity — not a silent prose-only gap. 1-safeness is not load-bearing
for this compiler/executor stack: the marking representation cannot express
multiplicity and the runtime never plays a token game.
