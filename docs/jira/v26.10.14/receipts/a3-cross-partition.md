# A-3 Receipt: Cross-Partition Multi-Entity Atomic Fan-Out — Transaction Semantics

- **Lane**: A-3 (adversarial cross-product bench)
- **Subject**: /Users/sac/smalt @ `518b31a54ccc0829cafb9e04538714e58c287a30`
- **Script**: `scripts/bench/a3_cross_partition_tx.exs`
- **JSONL**: `docs/jira/v26.10.14/bench/a3-cross-partition.jsonl` (2 runs x 4 tests)
- **Run**: `MIX_ENV=test mix run --no-start scripts/bench/a3_cross_partition_tx.exs`
- **Env**: OTP 28 / Elixir 1.19.5, darwin 26.2, 16 CPU, 48 GB. Cosmos surface driven at handler tier (`Smalt.DataPlane.Cosmos` — the same handlers the EgressRouter wires to HTTP).
- **No lib edits, no commits.** Substrate down after (bench VM exited; Store ETS was VM-local).

## Semantics-Verdict Table

| # | Surface probed | Witnessed behavior | Verdict | Real Azure parity |
|---|---|---|---|---|
| T1 | Batch surface existence (mechanical `module_info(:exports)` enumeration of `Smalt.DataPlane.Cosmos`) | `batch_ops_found: []` — only `create_doc/put_doc/delete_doc` exist | **UNSUPPORTED** | Real Azure has single-partition `TransactionalBatch`; absent here |
| T2 | Sequential 3-doc fan-out across 2 partitions, forced failure at doc 3 (pk-header/body mismatch → 400) | Docs 1-2 returned 201 and **stayed durable** after doc 3's 400 | **NONATOMIC** | Matches Azure: cross-partition ACID does not exist even in real Azure |
| T3 | Mid-batch simulated crash (stop after doc 2 of intended 3) | Docs 1-2 of 3 durable → partial state witnessed | **NONATOMIC** | Expected under sequential fan-out |
| T4 | App-tier 2PC-simulation: compensate-write (write 3; on failure delete written) | Happy: 14.5-14.6k batches/s (68.5-69 µs/batch, 3 doc-writes each); compensation end-state clean; **kill-before-compensate → partial state (NONATOMIC)** | **NONATOMIC under crash** | Expected: app-tier compensation is not crash-atomic anywhere |

## Divergence finding (KD-row candidate)

`GAP(cosmos-cross-partition-tx)` — but the sharper witnessed divergence is:
**no transactional-batch surface exists at all** (`batch_ops_found: []`, T1),
so **single-partition TransactionalBatch — which IS real Azure — is also
absent**. Cross-partition NONATOMIC is NOT a defect (real Azure lacks it too);
the single-partition batch absence is the true parity gap row.

## Measured (what exists)

- Sequential create: 201s with 400 on pk-mismatch — correct per-doc semantics.
- T4 compensate-write: 14,599 / 14,493 batches/s across runs (n=2,000 each,
  3 sequential ETS writes per batch), 68.5/69.0 µs per batch.
- Consistency-under-kill: compensation restores all-or-nothing on the normal
  failure path (end-state clean), but a kill between write and compensate
  leaves partial state — witnessed both runs (T4 `kill_midway_partial_state: true`).

## Falsifiers

- T1: a batch/transactional-batch export appearing on the Cosmos module.
- T2: docs 1-2 absent after a forced doc-3 failure without app-tier deletes.
- T4: kill-before-compensate leaving end state all-absent.

## Stability

T2/T3/T4 verdicts and booleans identical across both runs; T4 throughput
within 0.7% (14,599 vs 14,493 ops/s).
