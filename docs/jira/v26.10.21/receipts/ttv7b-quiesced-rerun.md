# TTV-7b: Quiesced Re-Run Gate (Warmed P99 Tail)

**Standing:** **BLOCKED-ON-QUIESCENCE**
Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt
Pre-registered gate (from `docs/jira/v26.10.21/receipts/ttv7-warmed-p99-standard.md`):
re-run `tmp/bench/ttv7_gl9_warmed.exs` once as-is; only if load < ~2× cores
(32 on this 16-core machine) may a sub-10µs tail claim be quoted. If the
ms tail reproduces at low load it is a REAL finding (typed defect, owner
dispatch). If load never drops below 32, type BLOCKED-ON-QUIESCENCE with
3 sampling passes 60s apart as evidence.

## Gate outcome: NOT MET — no quiesced re-run possible this window

Every 1-minute load sample across the window (20:01–20:14, ~13 min span)
was ≥ 84.5 — more than 2.6× the 32 gate, never approaching it:

| time | 1-min load | note |
|---|---|---|
| 20:01 | 159.02 | run start (peak; matches TTV-7's load-132 class) |
| 20:11 | 94.77 | 23 beam.smp processes resident |
| 20:12 | 87.07 | harness exit |
| 20:13 | 94.44 | sampling pass |
| 20:13 | 97.09 | sampling pass |
| 20:14 | 84.54 | window minimum — still 2.6× gate |

The load decayed (159 → ~85) but never crossed the gate; no sleeps were
used to wait it out, and this lane does not manage load (no lanes
launched or killed, per directive).

## Harness run as-is (load present, recorded honestly)

Pinned toolchain (Elixir 1.20.4-otp-29 / OTP 29.1.2), `MIX_BUILD_ROOT=_build-ttv7`,
`mix run --no-start`, exit 0, run-time load 159 → 87:

| profile | n | p50 µs | p95 µs | p99 µs | max µs | reds/step |
|---|---|---|---|---|---|---|
| COLD | 1_000 | 7 | 50 | 283,859 | 1,342,867 | 285.5 |
| WARM | 100_000 | 7 | 44 | 166,800 | 3,045,003 | 285.5 |

- Warm p99 **166.8 ms, max 3.05 s** — same order as TTV-7's load-132 run
  (197 ms / 3.06 s). Consistent with the load-class typing, but under the
  pre-registered gate this run **cannot** close the tail claim either way:
  load ≥ 32 throughout, so the falsifier (tail collapse to µs class) was
  not eligible to fire clean.
- Reductions stable: 285.5 reds/step, first-half 285.29 vs second-half
  285.73 (drift 0.154%) — governance cost unchanged, replicating TTV-7.
- Non-vacuity witness fired: refusal `SettlementShape/maxInclusive/amount`
  (pre-run guard compile + post-run refusal, typed andon).

## Verdict

Tail status remains **UNRESOLVED-under-load** (TTV-7 standing unchanged).
The quiesced re-run gate is restated exactly:

> Re-run `MIX_BUILD_ROOT=_build-ttv7 mix run --no-start tmp/bench/ttv7_gl9_warmed.exs`
> at load < 32 (1-min avg). If warm p99 collapses to the µs class, the
> load-class typing is CONFIRMED and the tail claim closes. If the ms tail
> reproduces at load < 32, escalate as a typed defect for owner dispatch.

## Commands

```
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
cp tmp/bench/ttv7-warmed-p99.jsonl tmp/bench/ttv7-warmed-p99.load132.jsonl   # prior evidence preserved
uptime; MIX_BUILD_ROOT=_build-ttv7 mix run --no-start tmp/bench/ttv7_gl9_warmed.exs   # exit 0
uptime   # 87.07 111.42 123.08 at exit
```

## Results files

- `tmp/bench/ttv7-warmed-p99.jsonl` (2 rows: COLD, WARM — this run, load ~87–159)
- `tmp/bench/ttv7-warmed-p99.load132.jsonl` (prior TTV-7 run preserved)

## Falsifiers

- Tail collapses at load < 32: **NOT ELIGIBLE** (load never below 84.5) —
  gate BLOCKED, falsifier neither confirmed nor refuted.
- Reductions drift under load: REFUTED again (0.154%, vs 0.073% in TTV-7).
- Prior run reproduction: warm p99/max within ~15% of TTV-7's values at
  comparable load — reproducible tail, not a one-off.

## Note

Do not commit (lane directive). No lanes were launched or killed; load was
observed only.
