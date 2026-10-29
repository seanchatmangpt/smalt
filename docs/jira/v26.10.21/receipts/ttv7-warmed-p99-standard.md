# TTV-7: Warmed-P99 Standard + Measured Cold/Warm Split

**Standing:** **PARTIAL_ALIVE** (standard landed; tail falsifier FIRED —
ms-tail reproduces warmed under load, so the "cold-start noise" premise
is refuted on this run; per-step compute cost exonerated via reductions)
Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt
Directive: operator TTV-7 (EXPANDED), `docs/jira/v26.10.21/DIRECTIVES.md`
Harness: `tmp/bench/ttv7_gl9_warmed.exs` (copy-and-extend of
`scripts/bench/gl9_governance_tax.exs`; original NOT edited — lane
ownership)

## Result

Guarded 4-step POWL2 settlement, pinned toolchain
(asdf OTP 29.1.2 / Elixir 1.20.4-otp-29), `MIX_BUILD_ROOT=_build-ttv7`,
`mix run --no-start`. Machine under heavy concurrent lane load:
**load average 132.8 on 16 cores** (`uptime` at run time).

| profile | n | p50 µs | p95 µs | p99 µs | max µs | reds/step |
|---|---|---|---|---|---|---|
| COLD (first 1_000, no burn-in) | 1_000 | 7 | 42 | 137,853 | 584,120 | 285.5 |
| WARM (post 10_000 burn-in) | 100_000 | 6 | 42 | 197,128 | 3,057,891 | 285.4 |

## Cold vs warmed split — measured, not assumed

- Median and p95 are identical cold vs warm (7→6µs, 42→42µs): burn-in
  confirmed the per-step code path is fully warm already after a few
  hundred iterations.
- **The warmed P99 did NOT collapse** toward the reductions denominator
  (sub-10µs). The operator premise ("tail is cold-start noise, warmed P99
  collapses") is **REFUTED on this run** — the pre-registered falsifier
  fired: warm p99 197,128µs (1.0%), max 3,057,891µs. COLD and WARM tails
  are the same order of magnitude, so the tail is NOT a cold-start
  artifact; combined with p50/p95 flatness and stable reductions it is a
  **load-class tail** (scheduler descheduling under load-132 on 16
  cores), not governance regression (reds stable) and not cold-start.
- Reductions (primary denominator, exact ints): warmed mean 285.45
  reds/step, first-half 285.35 vs second-half 285.55, **drift 0.073%** —
  stable ⇒ per-step governance cost unchanged vs gl9's 281–285 reds/step.

## Reductions cross-check

Primary denominator is reductions and it is stable; wall-clock warmed P99
(secondary) still breaches any sub-10µs reading by 4+ orders of magnitude
under this machine state. Per the standard: a warmed tail still breaching
is treated as real, never excused — the tail is recorded as
**UNRESOLVED-under-load**, with a quiesced-machine re-run
(load < ~2× cores) required before any sub-10µs tail claim is quoted.

## Standard landed

`docs/jira/v26.10.21/BENCH-ERLANG.md` § "Warmed-P99 standard (TTV-7)":
burn-in mandatory; dual COLD/WARM profiles mandatory; reductions primary /
wall-clock secondary with load context; cold-P99 reserved for boot/
recovery (JA-7) claims. Gl9 receipt carries the matching addendum.

## Commands

```
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
MIX_BUILD_ROOT=_build-ttv7 mix run --no-start tmp/bench/ttv7_gl9_warmed.exs
# exit 0
uptime   # load averages: 132.83 120.41 121.22 (16 cores)
```

## Results files

- `tmp/bench/ttv7-warmed-p99.jsonl` (2 rows: COLD, WARM)
- `tmp/bench/ttv7_gl9_warmed.exs` (harness)

## Falsifiers

- Warmed re-run reproduces the ms-tail ⇒ re-opens the threat: **FIRED on
  this run** (warm p99 197ms under load-132). Tail status:
  UNRESOLVED-under-load; quiesced re-run pending.
- Burn-in would flatten median/p95: CONFIRMED (median 6–7µs, p95 42µs
  identical cold vs warm — per-step path is compute-stable).
- Governance guard changes per-step cost: REFUTED (285 reds/step stable,
  drift 0.073% across 100k samples).

## Non-vacuity

Guard refusal witness fired post-run:
`SettlementShape/maxInclusive/amount` (typed andon, op never ran).

## Note

Do not commit (lane directive). Machine load was outside this lane's
control (concurrent lanes); numbers are reported as measured, with the
load context in the same row as the percentiles.
