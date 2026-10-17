# Receipt: lc2-tco-ledger

- **Lane**: LC-2 on `/Users/sac/smalt` (canonical checkout)
- **Date**: 2026-10-15/16
- **Owns**: docs/jira/v26.10.14/LIFECYCLE_TCO.md, docs/jira/v26.10.14/receipts/lc2-tco-ledger.md; one-line pointer added to docs/jira/v26.10.14/BENCH_RESULTS.md
- **Dependency**: LC-1 (`receipts/lc1-8hop-tax-chain.md`) — polled ~20 min, landed before authoring.

## Commands / exits

| Command | Exit |
|---|---|
| polling loop for `receipts/lc1-8hop-tax-chain.md` (30 s interval, ~20 min) | 0 (landed) |
| `Read receipts/lc1-8hop-tax-chain.md`, `CROSS_PRODUCT_RESULTS.md`, `BENCH_RESULTS.md`, `receipts/c9-cost-model.md`, `receipts/bench-12-consolidation.md` | 0 |
| `grep` for existing 238x/6204x multipliers on disk | 0 — not restated verbatim anywhere; cross-referenced to BENCH_RESULTS.md + `receipts/bench-*.md` per contract |
| `Write LIFECYCLE_TCO.md`, `Edit BENCH_RESULTS.md`, `Write this receipt` | 0 |
| No commits, no lib edits (per lane contract) | — |

## Consequence

`LIFECYCLE_TCO.md` authored with the five contracted sections:

1. **Measured 8-hop pipeline table** — per-hop p50/p95/p99 verbatim from
   LC-1's receipt (mapping labels preserved: REAL / NEAREST_ANALOG /
   SDK / PUT-journal), e2e p50 11.146 / p95 23.293 / p99 31.994 ms,
   200/200 cycles, 0 errors.
2. **Directive 1M-cycle Azure invoice** — the directive's published
   rates exactly as contracted (Entra $3.00, APIM $2,802.50 amortized,
   Cosmos $2.00, KV/HSM $18.20, EH $0.40, Blob $8.10, Search
   $4,000.00, Log Analytics $6.90, total ~$6,841/1M). Every rate
   labeled AS-OF-KNOWLEDGE/directional. Honest structural note added:
   the invoice is 99.5% flat-rate dominated (APIM+Search = $6,802.50);
   LC-1's op-metered ~$68.65/1M ledger differs by design (op-metered
   floor vs amortized-flat invoice).
3. **Measured local equivalent** — 200 cycles / ~2.7 s wall
   extrapolated to 1M cycles = 3.1–3.75 h; M3 Max amortization stated
   explicitly ($3,999 / 3 yr / 24×7 = $0.152/h) + power $0.012/h →
   ~$0.62/1M cycles.
4. **Arbitrage ratio with honest bounds** — point estimate ~11,000×,
   honest span 10³–10⁵× quoted (op-metered floor ~110×, pure-
   electricity ceiling ~150,000×). Bounds: loopback≠WAN (ratio is a
   lower bound on that axis), emulator≠cloud internals (hops 2/7 are
   labeled NEAREST_ANALOG; C-5 zero-429 divergence cited), single-host
   (local $0.62 is a floor). 238×–6204× SDK→BEAM multipliers
   cross-referenced to BENCH_RESULTS.md/bench receipts, not restated.
5. **C-9 cross-link** — `CROSS_PRODUCT_RESULTS.md` §4 referenced as the
   sustained-throughput complement, not duplicated.

`BENCH_RESULTS.md`: one-line pointer to LIFECYCLE_TCO.md added above
Methodology; generated tables untouched.

## Standing / gaps (honest)

- All dollar figures directional as-of-knowledge, not quotes.
- The directive invoice and LC-1's op-metered ledger are two different
  models; both presented, difference named, not reconciled (reconciliation
  requires the real APIM/Search tiers the directive amortizes).
- Local extrapolation assumes wall-clock scaling is linear from N=200;
  no 1M-cycle run was executed (would be ~3.5 h).
- The 238×–6204× multipliers are cited on the contract's authority; the
  per-lane bench receipts are the measurement record for them.
- M3 Max price/duty-cycle/power assumptions stated in §3; a different
  assumption scales the local line linearly.

## Replay

```
cat /Users/sac/smalt/docs/jira/v26.10.14/receipts/lc1-8hop-tax-chain.md
cat /Users/sac/smalt/docs/jira/v26.10.14/LIFECYCLE_TCO.md
grep -n "LIFECYCLE_TCO" /Users/sac/smalt/docs/jira/v26.10.14/BENCH_RESULTS.md
```

Every latency figure traces to LC-1's receipt; every dollar figure to
either the directive's contracted rates (§2) or the stated §3 formula;
arithmetic checkable by hand from the stated assumptions.

## Falsifier

- A latency figure in LIFECYCLE_TCO.md §1 not present in
  `lc1-8hop-tax-chain.md` falsifies this receipt.
- A directive rate in §2 differing from the contracted published rates,
  or any dollar figure presented without the directional caveat,
  falsifies it.
- The §3 local total not reproducible from the stated $/h rates x the
  stated hours falsifies it.
- A restatement of the 238×–6204× table (rather than a cross-reference)
  falsifies it.
