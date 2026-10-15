# Cosmos Bulk Stress — Receipt

Harness: `scripts/stress/cosmos_bulk.py` (stdlib-only Python).
Receipt: `tmp/cosmos_bulk_receipt.json` (schema `smalt-cosmos-bulk/v1`).

## Method

Real run against a live substrate spawned by the harness
(`mix run --no-start --no-halt --eval` with egress/AMQP/ARM ports pinned to
free non-default ports, since the shared checkout's default ports are
contended by concurrent lanes). Bearer token minted from the ARM STS
(`/oauth2/v2.0/token`) per beam; every measurement is a real HTTP round-trip
on the data plane (keep-alive, 16 threads). No mocks.

Scale: 20,000 docs, 10 partitions x 2,000, 16 threads, 256 B payload/doc.

## Receipt table (2026-10-14T21:47:53-0700, darwin/arm64, verdict PASS)

| Phase | n | p50 ms | p99 ms | wall s | rps | Notes |
|---|---|---|---|---|---|---|
| Bulk insert (10 pk x 2k, 16 thr) | 20,000 | 1.419 | 3.180 | 3.023 | 6,615.5 | 0 errors, all 201 |
| Point reads (2k random) | 2,000 | 1.024 | 2.690 | 0.239 | 8,369.3 | all 200 |
| Cross-partition query @20k | 20 | 38.333 | 55.977 | — | — | 100-cap respected; always full 100 |
| Deep pagination (100 page reqs) | 100 | 50.782 | 71.783 | 5.331 | — | no hang; see finding below |
| Delete sweep (20k) | 20,000 | 1.085 | 2.647 | 2.348 | 8,516.2 | residual docs after sweep: 0 |

Min/max: insert 0.23 / 9.61 ms; point reads 0.20 / 4.12 ms; query 32.4 / 56.0 ms;
delete 0.23 / 4.80 ms.

## Memory (substrate RSS, lsof->ps on the :egress listener)

| Sample | RSS KB | Delta |
|---|---|---|
| Before insert | 146,448 | — |
| After 20k inserts | 184,848 | +38,400 KB |
| After 20k deletes | 235,968 | +51,120 KB (no reclamation) |

Bytes/doc estimate (insert-phase RSS delta / 20,000): **~1,966 B/doc**
(RSS-derived; BEAM allocator retention makes this an upper-bound-noisy
estimate — the same harness on a quieter machine returned ~633 B/doc).

## Page-cap honesty (phase 3 + 4 findings)

1. The 100-cap is real and never hangs: at 20k-doc scale every cross-partition
   query returned `_count == 100` in p50 38 ms / p99 56 ms.
2. **No continuation token is emitted** (`x-ms-continuation` absent on every
   page). All 100 "pages" returned byte-identical first-100 document sets —
   the query surface has first-100 semantics only; deep pagination is NOT
   supported client-visibly. Recorded as a capability gap, not papered over.
3. The engine's `query_docs/4` scans the WHOLE container then filters/sorts in
   memory — cross-partition query cost grows with container size (38 ms at
   20k docs vs ~1 ms point ops). Linear-scan ceiling, not an index.

## Operational notes

- The delete sweep does NOT return memory to the OS: RSS grew 51 MB after
  deleting all 20k docs (Erlang allocator retention). Capacity planning must
  use peak-allocated, not current-doc-count.
- Harness spawns on dynamically pinned ports and retries boot up to 5x —
  the shared checkout's lanes pkill `beam.smp` and sweep default ports
  (8443/9443/5672) during runs; two runs were lost to this before the retry
  hardening.

## Reproduce

```
python3 scripts/stress/cosmos_bulk.py
```

The receipt's `verdict` field is the gate of record. On this shared host the
driver process may be SIGKILLed by external process reaping after the run
completes (observed: exit 137 post-receipt); check the receipt file, not the
exit code.

See Also: `docs/BENCHMARKS.md` · `scripts/bench.py`
