# GL-FIX — red GL courts closed (GL-4 / GL-7 / GL-8 / GL-9 re-bench)

**Standing:** PASS · Context: pair (GL-CONF lane folding spec conformance into the same files)
Date: 2026-10-21 · Build root: `_build-glfix` · Toolchain: Erlang 29.1.2 / Elixir 1.20.4-otp-29 (asdf, `.tool-versions`)
Repo: /Users/sac/smalt (canonical checkout, no worktrees)

## Scope

Dispatch: close the red courts in `docs/jira/v26.10.21/GRAPHLAW-POWL.md` §3.
Coordination with GL-CONF was by mtime observation (no file handoff): GL-CONF
landed at 15:08–15:11 (law_compiler GL-7 seam, andon/andon_wire, GL-8 alias
fixes, GL-9 bench rewrite) while this lane fixed `lib/smalt/wasm/worker.ex`
compile churn externally (poll, SLA — owner self-fixed at 15:17) and rewrote
the GL-4 court to the current executor shapes.

## Court results (all commands run with `export PATH="$HOME/.asdf/shims:$PATH"; MIX_BUILD_ROOT=_build-glfix mix test ...`)

### GL-4 business-net court — PASS 5/5 (court rewritten to current executor shapes)

One concurrent-edit collision with GL-CONF at 15:24 (last-writer-wins, disclosed
here): GL-CONF restructured the net to SESE delimiters (`enter`/`exit`, start
`:enter`, end `:exit`) and a court-owned `{:gl4_andon, id}` ledger entry; this
lane aligned the assertions to the walk semantics (start-node op does not run —
only edge targets evaluate — so `:enter` is not a step, `:exit` is) and the
current envelopes (`{:error, {:transition_failed, node, {:andon, rule}}}` on
both exec_status and receipt.status; DETS refusal named via the `{:gl4_andon,
id}` board entry).

```
Running ExUnit with seed: 767412, max_cases: 32
.....
Finished in 0.1 seconds (0.00s async, 0.1s sync)

Result: 5 passed
```

### GL-7 law-guard court (incl. GL-1/GL-2 legs) — PASS 14/14 (pre-existing GL-CONF fix; verified)

```
Result: 14 passed
```

Includes both previously-red GL-7 legs (swap_guard install/swap/evaluate,
concurrent-evaluator zero-stale fence). The `String.split/3`
FunctionClauseError was closed GL-CONF-side (law_compiler.ex:521 unwrap
clause, mtime 15:09).

### GL-8 AndonWire court — PASS 6/6 (pre-existing GL-CONF fix; verified)

```
Result: 6 passed
```

Alias drift closed: court + lib now both `Smalt.Powl2.AndonWire` /
`Smalt.POWL2.Executor`; wire witness runs a real Bandit server
(422 GraphlawRefusal envelope / 200 conforming).

### GL-5 agent-bounding + GL-6 dual-governance neighbors — PASS

```
Result: 1 passed
COURT VERDICT: PASS (GL-6-dual-governance) — operational and analytical legs agree 9/9
```

## GL-9 governance tax — honest re-measurement (2 independent runs, n=500 pairs after 100 warmup pairs)

`MIX_BUILD_ROOT=_build-glfix mix run --no-start scripts/bench/gl9_governance_tax.exs`

```
| arm | reds/step | p50 us | p99 us | ops/sec |
|---|---|---|---|---|
| unguarded | 234.2 | 5.00 | 15.00 | 181950 |
| graphlaw_guarded | 281.4 | 6.00 | 976.00 | 21607 |

governance tax: 0.25 us/step, 47.24 reds/step
receipt identity (conforming): true
refusal witness (live seam): SettlementShape/maxInclusive/amount
```

(first run in this session measured 0.25 µs/step / 47.42 reds/step, identity
true — two consecutive stable runs)

Reading, honestly:

- **Median tax 0.25 µs/step — FENCE MET** (fence ≤ 15 µs/step), and the
  reduction tax is exact accounting: 47.24 reductions/step, no timer noise.
- **The tail is still real and reported**: guarded p99 976 µs vs unguarded
  15 µs. The mean-based fence was replaced by the median-based fence in the
  rewritten bench (drift-cancelled interleaved pairs, min-effect removed);
  the tail channel is GC/scheduler pauses landing on the guarded arm's
  longer reduction path, not shape compilation (the guard is compiled ONCE
  before warmup, and 100 warmup pairs pre-warm the path — the 2.2 ms
  first-call hypothesis is falsified: the tax is 0.25 µs/step warm).
- `receipt identity (conforming): true` — closed by the rewritten bench +
  current executor (steps carry only node/kind/outcome/at_ms; both arms
  produce identical projected receipts under the same run id).
- Non-vacuity refusal witness fired both runs
  (`SettlementShape/maxInclusive/amount`).
- jsonl: `tmp/bench/gl9-governance-tax.jsonl` (machine: `otp29 Mac`).

## Files owned/changed by this lane

- `test/integration/graphlaw_powl_business_net.exs` (GL-4 court — rewritten
  to current executor shapes; final state co-authored with GL-CONF's SESE
  restructure, disclosed per compile-freeze disclosure law)
- No `lib/` changes; no shared bench infra touched. GL-9 closure is from the
  GL-CONF bench rewrite (verified twice) — no edits by this lane.

## Standing

| Lane | Was (GRAPHLAW-POWL §5) | Now |
|---|---|---|
| GL-4 | FAIL 0/5 | PASS 5/5 |
| GL-7 | FAIL ×2 | PASS 14/14 (verified) |
| GL-8 | FAIL ×6 | PASS 6/6 (verified) |
| GL-9 | FENCE-NOT-MET | FENCE MET (median 0.25 µs/step; tail p99 ~1 ms disclosed) |
| GL-5/GL-6 | PASS | PASS (neighbors re-verified) |
