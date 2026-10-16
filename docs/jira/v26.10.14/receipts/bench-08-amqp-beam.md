# Receipt: bench-08-amqp-beam (lane B-8)

- **Date**: 2026-10-15
- **Subject**: `/Users/sac/smalt` @ `518b31a54ccc0829cafb9e04538714e58c287a30` (main), working tree.
- **Lane**: B-8 — AMQP frame-tier (BEAM-level) throughput: `Smalt.Amqp.QueueStore` +
  `Smalt.Amqp.FrameCodec` driven in-process, below the SDK tier, above the wire.
- **Script**: `scripts/bench/b8_amqp_beam.exs`
- **Results**: `docs/jira/v26.10.14/bench/b8-amqp-beam.jsonl` (6 records, lib.sh row schema)
- **Method**: `MIX_ENV=test mix run --no-start scripts/bench/b8_amqp_beam.exs` — boots only the
  `:smalt_sb_*` + `:smalt_resources` ETS tables and the `QueueStore` claim/settle GenServer
  (mirrors `test/amqp/queue_store_test.exs` setup). No substrate, no sockets. `:timer.tc` wall
  timing per phase; whole-phase aggregate throughput (no per-op sampling); fresh run = fresh
  tables (script deletes nothing, boot clears tables, output file removed before each run).
- **Machine**: Apple M3 Max, 16 logical processors, OTP 28, Elixir 1.19.5, macOS 26.2.

## Headline numbers

| op | n | ops/sec | errors | notes |
|---|---|---|---|---|
| enqueue 1 KiB, 13 queues round-robin, growing to depth ~3.8k each | 50,000 | **826** | 0 | 60.5 s; dominated by the O(n) per-enqueue capacity check |
| dequeue+ack (dequeue_matching + complete), draining the 50k backlog | 50,000 | **419** | 0 | 119.4 s; O(n) claim candidate scan over the per-queue backlog |
| session round trip (session_acquire -> dequeue(session) -> complete -> session_release) | 4,000 | **870** | 0 | 4.6 s; bounded by the same serialized claim server |
| frame_codec transfer encode+decode+decode_message, 1 KiB body | 50,000 | **41,312 pairs/sec** | 0 | 1.2 s, pure BEAM, no GenServer |
| e2e store round trip (enqueue -> dequeue -> complete, depth ~1) | 50,000 | **35,959** | 0 | 1.4 s |
| enqueue 1 KiB depth-1 control (enqueue + complete per iteration) | 50,000 | **86,189** | 0 | 0.58 s — the true single-op floor |

## The depth pathology (primary finding)

The two bulk benches run ~100x below the depth-1 control:

- enqueue at depth: **826/s** vs **86,189/s** at depth ~1 → **~104x** slowdown
- dequeue+ack: **419/s** — every claim re-scans the remaining per-queue backlog
  (`QueueStore.claim_candidates` walks `:smalt_sb_messages` via `match_object`), and every
  enqueue re-counts the queue (`message_count/1` = `:ets.select_count` over the whole table).

Both are O(depth) per op → O(n^2) total. At 50k messages that is the entire measured cost:
the depth-1 control proves the machinery itself is fast (86k enqueues/s, 36k full
enqueue->dequeue->complete round trips/s at depth ~1).

Falsifier risk disclosed: the bulk benches measure this repo's *current* QueueStore scan
behavior at depth, not an asymptotic ceiling. Any O(1) capacity-check/claim-index change in
QueueStore would move these numbers by orders of magnitude without any other change.

## Frame tier

frame_codec sustains 41k transfer encode+decode (+ message-section decode) pairs/sec for 1 KiB
bodies — ~24 us/pair. This is the pure-BEAM wire-format cost per message; it is NOT the
bottleneck at any measured depth (store tier is 826/s at depth vs 41k/s codec).

## SDK→BEAM overhead ratio (B-4, measured same day)

> **SUPERSEDED 2026-10-16 by `receipts/x8-messaging-remeasure.md`**: the 122.6 ops/s
> SB RT below is recycle-contaminated; the remeasure on the KD-18/19/20-fixed
> substrate gives SB RT 95.2 ops/s (run2, complete 7-row jsonl) and a later
> canonical rerun gives 289 ops/s (n=13200). EH producer is now measurable at
> 323–348 events/s. The table below is retained as the pre-fix record; do not
> cite these multipliers as current.



`docs/jira/v26.10.14/bench/b4-messaging-ts.jsonl` (as of 2026-10-16T02:13Z) carries:
servicebus `send` = **0 ops/s** (n=0, 3 ServiceTimeout errors — substrate grants
`link_credit=1000` at attach and never replenishes; B-4 flags it as a KD candidate, so pure
send throughput is flow-crippled, not measured); servicebus `send+receive-complete-roundtrip`
= **122.6 ops/s** (n=4296, p50 3.99 s — dominated by the same link recycles, 2 errors);
eventhubs `producer-send` = **350.4 ops/s**.

Ratios (SDK ops/s divided into BEAM-tier ops/s, same 1 KiB payload class):

| BEAM anchor | BEAM ops/s | SDK ops/s (B-4) | SDK→BEAM multiplier |
|---|---|---|---|
| e2e store round trip (enqueue->dequeue->complete, depth ~1) | 35,959 | 122.6 (send+receive-complete RT) | **~293x** |
| enqueue depth-1 control | 86,189 | 122.6 | ~703x |
| enqueue at depth (scan pathology) | 826 | 122.6 | ~6.7x |
| frame codec enc+dec pairs | 41,312 | 122.6 | ~337x |

Headline: the SDK round trip runs ~293x below the BEAM store round trip — but B-4's number is
contaminated by the flow-control KD candidate (fixed link credit, forced sender-link recycles,
multi-second p50s). Treat ~293x as an upper bound on apparent overhead; the true SDK→BEAM
multiplier is bounded below by the store-RT anchor alone. Either way the ordering is unambiguous:
SDK RT 122.6/s < dequeue+ack 419/s < depth enqueue 826/s < e2e store RT 35,959/s — the dominant
cost at depth is the store's O(depth) scans, not the codec (41,312 pairs/s) or the wire.

## Verification

- 6/6 JSONL rows carry `errors: 0`; 50k+50k+50k+50k+4k ops executed and matched ({:ok,_}
  pattern-matched on every op — any error shape would have raised MatchError).
- Pre-check in frame bench pattern-matches a full encode->decode->decode_message round trip
  before timing; a mismatch raises.
- Rerun reproducibility: three full runs this session (run-to-run agreement within ~5%:
  enqueue 826/846/826, dequeue 456/438/419, frame 44.3k/43.9k/41.3k, e2e 36.4k/42.3k/36.0k).
- No lib edits, no commits. Only files written: `scripts/bench/b8_amqp_beam.exs`,
  `docs/jira/v26.10.14/bench/b8-amqp-beam.jsonl`, this receipt.
