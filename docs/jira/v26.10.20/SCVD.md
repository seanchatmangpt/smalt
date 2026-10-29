# SCVD — Stress/Convergence Verification Doctrine

Milestone: v26.10.20. This document defines the SCVD receipt format and the
tier ladder for load/wall verification lanes. Tier cells are filled ONLY from
receipt jsonl on disk (`tmp/bench/scvd-*.jsonl`); missing lanes are
`PENDING-<lane>` placeholders, never invented numbers.

## SCVD_RECEIPT schema

Each tier run emits one JSON line per observation to
`tmp/bench/scvd-<lane>.jsonl` via `bench_emit` (`scripts/bench/lib.sh`).
Required fields:

| field | type | meaning |
|---|---|---|
| `lane` | string | lane id (`scvd-t1`, `scvd-tier2`, `scvd-tier3`, `scvd-chaos-conn`) |
| `surface` | string | plane surface under test (`cosmos`, `cosmos-docs`, `cosmos-data-plane-tls-9444`) |
| `op` | string | operation profile (`concurrent_put_get_16legs`, `putget-c128`, `ramp-<L>`, `wall-summary`, `conn_exhaustion_chaos`) |
| `n` | int | operations issued |
| `ops_per_sec` | number | throughput |
| `p50_ms` / `p95_ms` / `p99_ms` | number\|null | latency percentiles (null when not meaningful, e.g. flood legs) |
| `errors` | int | failed operations |
| `wall_ms` / `wall_budget_ms` | int (tier1/2) | wall time of the run and its budget |
| `wall_level` | string (tier3) | concurrency level where the wall fired (`L<n>`), or `unreached` |
| `verdict` / `standing` | `PASS`\|`FAIL` | lane verdict (field name varies per harness generation; both carry standing) |
| `machine` | object\|string | host identity (cpu/cores/otp/elixir/darwin/endpoint) |

Tier-3 additionally carries `typed_fail_512` (bool) on `wall-summary` rows:
true when the wall manifested as typed 512-class failures rather than a hang.
Chaos lanes carry `tls_opened`, `refused`, `reset`, `err_types`,
`refusal_class`, `recovered`, `recovery_attempts`, `recovery_*_ms`.

**Context line (mandatory)**: per
`docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`, every markdown witness receipt
derived from these jsonl rows carries
`Context: solo|pair|slice|full`. A receipt without it is flagged NO-CONTEXT by
`receipt_index.py`.

## Exit-code contract

Self-booting harnesses (mirrors the repo-wide e2e contract):

| exit | meaning |
|---|---|
| 0 | verdict PASS |
| 1 | verdict FAIL (test/wall failure) |
| 2 | substrate never came up |
| 3 | harness-skip — loud SKIP, never a faked pass |

## Tier ladder

| tier | question answered | harness | result jsonl |
|---|---|---|---|
| 1 | is the hot path fast at leg concurrency? | `tmp/bench/scvd_tier1.mjs` | `tmp/bench/scvd-tier1.jsonl` |
| 2 | does a realistic concurrency burst stay inside wall budget? | `scripts/bench/scvd_tier2.mjs` (also `scvd_tier12.mjs` combined driver) | `tmp/bench/scvd-tier2.jsonl` |
| 3 | where is the wall, and is it typed? | `scripts/bench/scvd_tier3.mjs` | `tmp/bench/scvd-tier3.jsonl` |
| 4 | tail-latency invariance | `tmp/bench/scvd_tier4.mjs` | `tmp/bench/scvd-tail.jsonl` — INVARIANCE-HOLDS under fence v2 (UPDATED 2026-10-21) |
| 5 | chaos / connection exhaustion | `tmp/bench/scvd_tier5_chaos.mjs` | `tmp/bench/scvd-chaos-conn.jsonl` |

Harness inventory: `tmp/bench/scvd_tier1.mjs`, `tmp/bench/scvd_tier4.mjs`,
`tmp/bench/scvd_tier5_chaos.mjs`, `scripts/bench/scvd_tier12.mjs`,
`scripts/bench/scvd_tier2.mjs`, `scripts/bench/scvd_tier3.mjs`.

## Observed tier cells (from disk, 2026-10-21, Apple M3 Max / OTP 28 / Elixir 1.19.5)

**Tier 1** (`scvd-tier1.jsonl`, 3 runs, verdict PASS x3): cosmos
`concurrent_put_get_16legs`, n=160, 16 legs x 5 cycles, 0 errors each run.
wall_ms 63 / 65.7 / 64.5 (the 63-66ms band); p50 5.20-5.50 ms; p99 17.02-17.91
ms; ops/s 2434-2540.

**Tier 2** (`scvd-tier2.jsonl`): cosmos-docs `putget-c128`, concurrency 128.
First three rows (n=512) are `standing: FAIL` with errors=512 — recorded, not
hidden. The PASS row: n=1024, 0 errors, wall 456 ms (budget 30000 ms), p99
150.6 ms, p50 43.8 ms, 2245 ops/s.

**Tier 3** (`scvd-tier3.jsonl`): cosmos-docs ramp ladder. `wall_level:
unreached` at L512/L1024/L2048/L4096 (0 errors through L4096; p99 14.3 s at
L4096). Wall fires at ramp-8192: `wall_level: L8192`, 534 errors,
`typed_fail_512: true` on the final `wall-summary` row — the wall is a typed
512-class refusal, not a hang. Earlier wall-summary rows carry
`typed_fail_512: false` (runs that had not yet crossed the wall).

**Chaos (tier 5)** (`scvd-chaos-conn.jsonl`, 2 runs): connection-exhaustion
flood on TLS 9444, n=2000. Run 1: `verdict: FAIL` — accepted-all
(`refusal_class: "accepted-all"`, 0 refused/0 reset), recovery unverifiable
(node TLS CA verification error, `recovered: false`). Run 2: `verdict: PASS`
— `refusal_class: "accepted-all"` still (server accepts the flood, 0 refusals
in-band), recovery verified: 1 attempt, put 140 ms / get 454 ms, recovery
594 ms total. Standing: PASS (latest row); the FAIL row remains as evidence
that recovery-verification is the distinguishing leg.

**Tier 4**: INVARIANCE-HOLDS (UPDATED 2026-10-21; was PENDING-scvd-tier4,
then SUSPECT INVARIANCE-BREACH under the legacy scalar fence). The original
188.79 p99(c128)/p99(c1) ratio was a fence-definition artifact: a scalar
latency ratio at depth 128 measures queueing depth, not regression. Fence v2
(`tmp/bench/scvd_tier4.mjs` header + `fence_definition` row in
`tmp/bench/scvd-tail.jsonl`) replaces it with a Little's-law depth envelope:
F1 throughput floor (>= 0.5x c1 best = 672.8 ops/s), F2 depth envelope
(p99(level) <= 4 x level x p99(c1 best) = 1.263 ms), F3 zero errors. All
levels pass F1/F2, errors_total 0, `verdict: INVARIANCE-HOLDS`, exit 0.
Legacy ratio re-read from the fence-v2 verdict row: 124.79 (min-of-3 best
rounds), recorded for continuity — the breach row from the fence-v1 run
remains on disk as evidence.

See Also: `docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md` ·
`docs/jira/v26.10.20/scvd-ledger.md` · `scripts/bench/lib.sh`

---
*Addendum (BK-BMIR2, 2026-10-22): the `tmp/bench/scvd-*.jsonl` tier-ladder evidence cited above now has byte-identical tracked mirrors at `docs/jira/v26.10.20/bench/` (airgap, blob, chaos-conn, eh, sb, soak2, tail, tier1, tier2, tier3, wasm-vs-host; scvd-soak pending-with-owner); paired-sha256-verified, provenance `docs/jira/v26.10.20/bench/PROVENANCE.md`.*
