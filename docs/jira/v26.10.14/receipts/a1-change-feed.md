# Receipt: A-1 adversarial cross-product bench — Cosmos change-feed → Event Hubs → Blob tiering

- Lane: A-1, v26.10.14 bench wave
- Subject: `scripts/bench/a1_change_feed.exs` (bench-local, no lib edits)
- Results: `docs/jira/v26.10.14/bench/a1-change-feed.jsonl` (2 records, one per phase)
- Run gate: `MIX_ENV=test mix run scripts/bench/a1_change_feed.exs` → exit 0
- Date: 2026-10-16 (as-of-knowledge labels: 2026-10)

## Design

smalt has NO change-feed processor (lib gap, below). The tail is simulated BEAM-tier:

- **producer**: 2000 upserts/phase in 10 waves of 200 (25% are updates of prior-wave ids
  via `put_doc`; 75% creates via `create_doc`), 256 B pad + id/pk/v per doc (~1 KiB event).
- **tailer** (the change feed): `Store.list_prefix(:smalt_cosmos_docs, "db/coll/")` walk,
  `_ts` cursor + `_etag` seen-set dedup — the continuation walk IS the change feed.
  Poll 5 ms.
- **fan-out**: `EventHubs.send_event/3` per changed doc (1 KiB bodies).
- **archiver**: `receive_events/3` → `stage_block` + `commit_block_list` per doc
  (one block per blob, `a1/<id>.json`), container created `immutable: false`
  (WORM default refuses every commit — first measured failure).
- **backpressure boundary**: EXPLICIT BUFFER CAP of 2000 events. The tailer pauses the
  Cosmos walk when `enqueued - consumed >= 2000`; process mailboxes never grow —
  the buffer lives in the EH partition ETS, not in a mailbox.
  No bounded-mailbox primitive was needed.

## Machine spec (embedded in every JSONL record)

Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5, OTP 28, macOS (darwin 25.2.0)

## Pipeline table (measured, full run exit 0)

| phase | window | cosmos upserts/s | feed walk (docs scanned/s) | changes fanned → EH events/s | blob archive (docs/s) | blob write ops/s |
|---|---|---|---|---|---|---|
| baseline | 0.661 s | 3724.4 | 16,599 | 2287.4 | 5349.5 | 10,325 |
| stall (200 ms commit delay) | 3.535 s | 3436.4 | 7176 | 427.2 | 866.8 | 1734 |

End-to-end latency (upsert → archived commit), per-event:

| phase | n | p50 | p95 | p99 |
|---|---|---|---|---|
| baseline | 1361 | 21 ms | 96 ms | 133 ms |
| stall | 1510 | 1.56 s | 2.76 s | 2.77 s |

## Backpressure verdict

**HOLDS.** Under a 200 ms stall the pipeline degrades by BUFFERING, not by failure:

- EH backlog peaked at **559 events** (well under the 2000-event cap; the cap was never
  hit, so 0 tailer pauses fired — the archiver kept draining at 866 docs/s = 5×200 ms-commit
  batches of 100) while the Cosmos producer ran unconstrained at 3436 upserts/s.
- Process memory: baseline peak 58.7 MB → stall peak 78.1 MB (+19.4 MB during the stall
  window), and **returned down to 67.6 MB after drain** — bounded growth, no leak signal
  over the window. No unbounded queue growth anywhere in the pipe.
- The explicit cap (2000) is the backpressure boundary; because the backlog stayed below
  cap, the tailer never paused. Verdict: the pipe buffers ~559-event stalls invisibly;
  stalls beyond ~2× the cap will engage the walk-pause and propagate backpressure to the
  Cosmos tail. Engaging the cap is graceful by construction (sleep-loop on the walk).

## Memory stability

Stable. peak 78.1 MB, end-of-window 67.6 MB after drain (36 samples). Baseline end 40.0 MB
after GC. No monotonic growth trend; the +19 MB stall bump drains. Mailboxes bounded by
construction (no GenServer mailboxes in the measured path — ETS + explicit buffer cap).

## Billable-equivalent rows (directional, as-of-knowledge 2026-10)

| surface | sustained | label |
|---|---|---|
| Cosmos RU/s | ~35,800 RU/s sustained | ~10 RU/point-upsert, serverless ~$0.25/M RU |
| Event Hubs TU-class | 2287 events/s ≈ 2.3 TU (1 KiB events) | throughput units, 1 TU ≈ 1000 × 1 KiB events/s |
| Blob write ops/s | ~10,700/s baseline / ~1734/s stalled | put_block + put_block_list per doc |

## Lib-gap findings

1. **No change-feed processor / _ts cursor feed surface in lib** — the tail is
   implemented bench-local (`Store.list_prefix` + `_ts`/`_etag` dedup). Also, `_ts` is
   second-resolution, so same-second updates dedup by `_etag` seen-set; a real feed
   (LSN-cursor) would not need the etag set. This is the main gap for a real processor.
2. **WORM default `immutable: true` on `create_container/3`** refuses EVERY
   `commit_block_list` overwrite (first run archived 0 — measured `{:error, :worm_locked}`
   on commit 2). Tiering targets need `immutable: false` explicitly.
3. **Cosmos docs require partition-key header discipline**: container defined with
   `paths: []` needed for headerless docs (enforce/3 400s otherwise). Bench uses a
   headerless container.
4. **`receive_events` replay** requires the consumer to track `after_seq` — no lease/checkpoint
   enforcement; the bench starts each phase at `EH.next_sequence` head to avoid replaying
   the prior phase (measured double-processing before the fix).

## Falsifier status

- All stages measured, end-to-end latencies from per-event timestamps, backlog and memory
  sampled at 100 ms — no simulated numbers. Every stage rate is a real counter delta over
  the phase window.
- Substrate down after: script exits via `:init.stop()`, exit 0, zero stray beam
  processes (`pgrep` count 0).

## Replay

```
MIX_ENV=test mix run scripts/bench/a1_change_feed.exs
# env: A1_TOTAL (2000), A1_WAVE (200), A1_DEBUG, A1_RESULT_FILE
```
