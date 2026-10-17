# A-7: HNS Massive Recursive Rename (ADLS Gen2 parity probe)

- **Date**: 2026-10-15
- **Lane**: A-7 (adversarial cross-product bench)
- **Script**: `scripts/bench/a7_hns_rename.exs` (BEAM tier, `mix run --no-start`, Store/BlobStorage direct)
- **JSONL**: `docs/jira/v26.10.14/bench/a7-hns-rename.jsonl` (9 events)
- **Gap**: `GAP(blob-hns-atomic-rename)` — smalt's blob layer stores blobs as flat ETS keys
  (`:smalt_blobs`, key `"acct/cont/a/b/c"`), virtual directories only; there is no rename API.
- **Subject**: smalt @ main, working tree fd9cfea+bench-lane edits, `MIX_ENV=test`.

## Method

1. **Fixture** — 100k blobs under `src/`, 8 virtual-directory depth levels (deterministic
   `path/1`), written via `Smalt.Store.put` at fixture speed (~630k puts/s).
2. **Simulated rename** — enumerate `Store.prefix_keys(:smalt_blobs, src)` + re-key each
   (ETS insert-new + delete-old, plain reduce so the process is killable mid-flight).
   Milestones at 10k/50k/100k; `:erlang.memory(:ets)` sampled.
3. **Atomicity witness** — spawned renamer hard-kills itself (`Process.exit(self(), :kill)`)
   exactly 3,000 re-keys into a fresh 20k-blob rename; post-kill prefix counts recorded.
4. **Concurrent reads** — 60k probes interleaved with the 100k rename: even probes on OLD
   names, odd probes on NEW names; counted found vs 404.

## Rename cost table (measured, single run)

| items | wall (ms) | items/s | ETS (MB) |
|---|---|---|---|
| 10,000 | 101.0 | 99,049 | 33.9 |
| 50,000 | 214.2 | 233,385 | 33.9 |
| 100,000 | 336.9 | 296,864 | 33.9 |

Fixture: 100,000 puts in 162.4 ms (640,816 puts/s), ETS 1.1 MB → 33.9 MB (+32.8 MB / 100k blobs).

## Atomicity verdict

**NON-ATOMIC, witnessed.** After a mid-rename hard kill at 3,000 re-keys, the tree was left in
a mixed-prefix state: `old_prefix_remaining=17,000` under `k2src/`, `new_prefix_moved=3,000`
under `k2dst/`. The partial rename persists after crash. A real ADLS Gen2 rename is a single
O(1) atomic metadata parent-repoint — crash leaves either all-old or all-new, never mixed.

## Concurrent-read consistency (during 100k rename)

| probe | found | 404 |
|---|---|---|
| old name | 29,961 | 39 |
| new name | 41 | 29,959 |

Readers on both sides of the rename see a **stale/404 window**: old-name reads straddle
found→404 and new-name reads straddle 404→found as the re-key front passes each blob. On real
ADLS Gen2 a rename is atomic — every reader sees old-or-new, 404s are impossible mid-rename.

## Real-ADLS comparison row

| surface | rename semantics | complexity | atomicity | reader view |
|---|---|---|---|---|
| smalt (simulated re-key) | enumerate + copy+delete every blob | O(n), ~297k items/s, 337 ms @ 100k | non-atomic, mixed prefixes after crash | stale/404 window during rename |
| real ADLS Gen2 | single metadata parent-repoint | O(1), sub-ms | atomic | old-or-new, never 404 |

## Verdict

`GAP(blob-hns-atomic-rename)` confirmed by execution: no rename API exists, and the only
simulable equivalent is O(n), non-atomic, with a live stale/404 reader window. Divergence
magnitude: **O(n) vs O(1)**.

## Notes

- Concurrent-read counts above are from the reader process racing the main 100k rename;
  the reader samples only ~half the keyspace per 30k probes per side, so found/404 splits
  reflect the sampling frontier, not a 50/50 window — the window itself is the finding.
- No lib edits; single bench script + JSONL + this receipt. Substrate Store cleared at end
  (`Smalt.Store.clear/0`); run exit 0.
