# IMPL-15 — AR-POWL-03 decomposition-leg adoption (writer, OTP-29)

Context: pair(concurrent commit 168a4e3 landed shared lib/ deltas mid-session)

**Standing: ALIVE** (court green on OTP 29.1.2; cross-engine equivalence maintained)

## Subject

- Repo: /Users/sac/smalt @ main (HEAD at session start `b87092d`; concurrent commit
  `168a4e3` landed the lib/ deltas mid-session)

## What landed

AR-POWL-03 adoption extended from compiler.ex to decomposition.ex:

- `lib/smalt/powl2/decomposition.ex` — `block_order_edges/2` (induced
  group-order quotient graph on the net's arcs), `block_order_acyclic?/2`
  (routes through `GraphCompat.acyclic?/1`, same engine seam as
  `Compiler.order_cycle_check!/1`), `block_cycle_check!/2` (typed refusal
  `throw({:powl2_refusal, :block_order_cycle})`), wired into
  `partition_mg/1` and `partition_sm/1` after union-find grouping.
- `test/internal/powl2_graph_compat_court.exs` — decomposition leg:
  real Petri net (src→a1→p1→b1→p2→a2→snk) with a hand-partition whose
  quotient graph is A→B→A; cyclic block order refused by BOTH engines
  (native :graph and elixir DFS agree false), typed refusal witnessed via
  `catch_throw` == `{:powl2_refusal, :block_order_cycle}`; acyclic
  chain partition admitted with native/elixir agreement; real
  `partition_mg/1` run non-regressing.

## Session note (lane accounting, same-checkout disclosure)

At session start, `decomposition.ex` did NOT contain the check. My edit
added it; commit `168a4e3` ("landed lib deltas from closers") then landed
a byte-identical lib/ version mid-session (`git diff HEAD` on the file is
now empty). The session's remaining uncommitted delta is the court leg
(59 lines in `test/internal/powl2_graph_compat_court.exs`). This is a
coincidence-of-naming disclosure under the compile-freeze SLA, not a
conflict — content matches, no lane blocked.

## Diff

```
 lib/smalt/powl2/decomposition.ex          | (landed via 168a4e3; session edit converged byte-identical)
 test/internal/powl2_graph_compat_court.exs | 59 ++++++++++++++++++++++++++++++
```

## Commands + output

```
$ PATH=$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH \
  MIX_BUILD_ROOT=_build-impl15 mix test test/internal/powl2_graph_compat_court.exs test/internal/powl2_decomposition_test.exs test/internal/powl2_compiler_test.exs
Running ExUnit with seed: 40570, max_cases: 32
.....................................
Finished in 0.06 seconds (0.06s async, 0.00s sync)
Result: 37 passed

$ MIX_BUILD_ROOT=_build-impl15 mix test test/internal/powl2_graph_compat_court.exs --seed 0
Result: 8 passed
```

8 = 5 pre-existing court tests + 3 new decomposition-leg tests. Decomposition
and compiler suites stay green (no regression from wiring the check into
`partition_mg/1` / `partition_sm/1`).

## Environment

- Toolchain: OTP 29.1.2 + Elixir 1.20.4-otp-29 (asdf, repo OTP-29 lane PATH)
- MIX_BUILD_ROOT=_build-impl15

## Falsifier status

Cross-engine equivalence held cell-by-cell on the corpus and on the new
decomposition edges — no disagreement witnessed; court not flipped.
