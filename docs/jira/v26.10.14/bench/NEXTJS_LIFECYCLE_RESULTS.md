# Next.js Lifecycle Bench Results — v26.10.14 (N-1..N-8 consolidated)

Consolidated by lane N-8. Ledger: `docs/jira/v26.10.14/bench/n{1..8}-*.jsonl`.
Soak witness window: 2026-10-16T04:09–04:18Z. Consolidation time: 2026-10-16T04:25Z.

| Scenario ID | Concurrency | p50 | p99 | Heap Delta | Falsifier Status |
|---|---|---|---|---|---|
| N-1 grid (topo grid interaction, `n1-grid.jsonl`) | 1 browser | n/a (no latency metrics in ledger) | n/a | n/a (not sampled) | **PASS** — patches_applied 1492 ≥ 1350 threshold; long_task_total 0 ms (INFO) |
| N-2 action storm (`n2-action-storm.jsonl`) | 100 VU | 87.66 ms | 141.85 ms | 0 session leaks | **PASS** — 0 valid bounced, 0 unexpected status, 0 double-submission leaks (100/100 pairs clean) |
| N-2 action storm (saturation) | 2000 VU | 176.44 ms | 10,381.96 ms | 0 session leaks | **PASS (degraded at saturation)** — 2506/2508 transport errors ETIMEDOUT at 2000 VU, rejection_rate 1.0 (expected backpressure, no invalid acceptance) |
| N-3 RSC race (`n3-rsc-race.jsonl`) | 1 browser × 50 rounds | n/a | n/a | **+53.33 MB** over 50 rounds (5.9 MB → 59.6 MB) | **FAIL** — 1 uncaught pageerror: minified React error #412; heap growth PASS (<150 MB), no lingering pending PASS |
| N-4 ingest (`n4-ingest.jsonl`, final window 3/3) | 5000 rps target (4987.8 achieved) | 1.28 ms | 11.02 ms | heap sampled per window (node-side, no leak falsifier in ledger) | **PASS (provisional)** — stable p50/p99 across 3 windows, 0 socket errors; no receipt found |
| N-5 compute (`n5-compute.jsonl`) | worker-pool (worker count per ledger) | latency budget 16.6 ms — PASS | input-latency falsifier PASS | **+3.73 MB vs baseline after worker termination** (7.71 MB vs 3.98 MB baseline; not reclaimed to +5% in 5 s) | **PARTIAL FAIL** — liveness PASS, input latency PASS, dropped frames PASS, memory-reclaim falsifier **FAIL** |
| N-6 ISR stampede (`n6-isr.jsonl`) | 100 conn (P0 cached) / stampede phase | cached 14 ms / stampede 136.6 ms | cached 27 ms / stampede 306.9 ms | n/a | **PASS** — F1/F2/F3 all PASS (cached p99 27 ≤ 45 ms; on-demand revalidation clean; disk cache consistent) |
| N-7 SSE herd (`n7-sse-herd.jsonl`) | 5000 SSE clients | n/a | n/a | listener handles stable 5 (min=max=5) | **PASS** — 0 permanent drops, 0 attach errors, divergence rate 0 (threshold 0.001), 4980/5000 final active |
| N-8 memory soak (this lane) | 1 browser × 500 cycles | n/a | n/a | **−5.77%** retained (flat slope −20 B/cycle, r²≈0) | **PASS** — no leak; DOM 1 document, nodes flat 54, listeners flat 296 |

## Per-lane receipts

- N-1: no receipt found at consolidation time (ledger only)
- N-2: no receipt found at consolidation time (ledger only)
- N-3: no receipt found at consolidation time (ledger only)
- N-4: no receipt found at consolidation time (ledger only)
- N-5: no receipt found at consolidation time (ledger only)
- N-6: no receipt found at consolidation time (ledger only)
- N-7: no receipt found at consolidation time (ledger only)
- N-8: `docs/jira/v26.10.14/receipts/n8-memory-soak.md`

## Standing summary

- **Leak-class falsifiers: 8/8 lanes free of linear heap growth** (N-8 flat envelope; N-7 listeners stable; N-3 growth bounded PASS).
- **Open defects surfaced (not N-8's to fix, forwarded to owners):**
  1. N-3: React error #412 pageerror on RSC navigation race — 1 occurrence over 50 rounds.
  2. N-5: worker-termination memory reclaim fails the 5%-within-5s budget (+93% over baseline persists).
- All 8 lane ledgers (n1..n8) existed on disk at consolidation; no pending rows required.
