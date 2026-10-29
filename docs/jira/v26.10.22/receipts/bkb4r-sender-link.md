# BK-B4R — b4 messaging sender-link root cause + fix

- **Standing**: ALIVE — b4 delivers end to end; SUSPECT-PERMANENT row flipped to ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-B4R
- Input: `docs/jira/v26.10.22/receipts/bkbquiet-quiesced-bench.md` (b4 typed
  FAIL louder: "SB send 0/2000, CBS put-token 200 ×1,717 — the face is the
  sender link")

## Diagnosis (instrumented, not inferred)

Reproduced deterministically on the private block 39040..39045: even the
FIRST send on a fresh client failed — not load. A temporary env-gated
B4R-TRACE patch on `connection.ex` (added, run, reverted in-session) showed
the wire truth per attempt:

```
in :attach ch=1 handle=0            (client-sender attach, queue entity)
out :attach echo + out :flow credit=1000 delivery_count=0   (healthy)
in :transfer ch=1 handle=0
out :detach ch=1  MessagingEntityNotFound: The messaging entity "b4-send-1792680182397"
   could not be found. Create the entity before sending, or enable
   config :smalt, :sb_auto_ensure.
in :detach echo / :end / :close
```

So the "sender-link face" from BK-BQUIET was actually the KD-86 entity gate:
attach is healthy, credit flows, and the transfer is settled by DETACH with
`MessagingEntityNotFound` — the SDK then retries into the harness's 20s op
timeout. CBS put-token stayed 200 because `$cbs` never touches the queue
entity gate. The credit-starvation / settlement hypotheses are refuted.

## Root cause

The KD-86 gate (`queue_store.ex ensure_entity/1`, landed fe4a3d83,
2026-10-21) consults ONLY `:smalt_sb_queues` (emulator-lazy rows); an entity
created through the MANAGEMENT plane (ARM gateway PUT / ATOM alias) lives in
`smalt_resources` with no `:smalt_sb_queues` row → every send to an
ARM/ATOM-created entity refused `MessagingEntityNotFound` (sender link
detached). Real Azure: a management-plane-created entity is sendable. The
harness never provisions entities (predates KD-86, relied on removed
emulator auto-create), so the two defects compounded.

## Fixes

1. **lib (messaging owner surface)** — `lib/smalt/messaging/amqp/queue_store.ex`:
   `ensure_entity/1` now admits an ARM resource record as entity existence
   (reuses `arm_queue_properties/1`'s downcased-suffix scan over
   `:smalt_resources` — the same scan `queue_settings/1` already runs on the
   success path) and materializes the `:smalt_sb_queues` row.
2. **harness** — `scripts/bench/b4_messaging_ts.mjs`: provisions
   `b4-send-<ts>` / `b4-rt-<ts>` entities over the ARM ATOM alias
   (PUT, expect 200/201, exit 3 on failure) before measuring;
   queue names hoisted to SEND_QUEUE/RT_QUEUE consts shared with the phases.

## Rerun (real, exit 0)

```
substrate up on ports 39040/39041/39042/39043/39044/39045 after 2005ms (pid 46083)
provisioned queue b4-send-1792680708470 (201) / b4-rt-1792680708470 (201)
(a) SB send: 2000 msgs in 40s = 50.6 msgs/s p50=0.25ms errs=4 clientRecycles=2
(b) SB round-trip: sent=2000 completed=2000 => 50.3 round-trips/s p50=370.98ms errs=3
(c) EH producer: 5625 events in 30s = 187.5 events/s p50=5.34ms errs=0 recycles=22
(c) EH rhea wire-tier consumer: received 0 events (seq annotated: 0), sdk subscribe ok=true
```

Confirmation run (send-only): 2000 msgs, errs=4, clientRecycles=2 —
deterministic.

## Typed residual

4 (a) + 3 (b) fast `AggregateError` aborts (empty message, client-side only;
no server detach/unauthorized in the substrate log) riding the harness's
client-recycle idiom (`consecutiveErrs>=2 → closeSoon(client.close())`
aborts the in-flight awaited op and the abort is counted as the next error).
0.2% of ops; every measured window delivers its full 2000. Falsifier for
this typing: a non-empty AggregateError message or a server-side detach in
the substrate log refutes the "recycle artifact" typing and reopens the row.

## Gates

- `mix compile` (MIX_ENV=test) clean on the fixed tree (pre-existing
  ash_r2rml type warning only, untouched).
- Canonical `b4-messaging-ts.jsonl` restored byte-exact to HEAD; this run's
  rows snapshotted at `tmp/bkb4r/b4-messaging-ts-bkb4r-run.jsonl`.
- Index/RECEIPTS.md regen is coordinator-owned (concurrent lanes hold those
  files dirty) — not run this lane.

## Falsifier

1. Re-run b4 on the fixed tree: sends deliver 2000/2000; a run that fails
   every send with MessagingEntityNotFound again refutes the fix.
2. The b4 REGISTRY row's ALIVE typing stands only with this receipt; any
   later run that cannot deliver >0 sends reopens the row.
3. The recycle-artifact typing of the 4+3 AggregateErrors is refuted by a
   non-empty AggregateError message or a server-side detach in the
   substrate log.

## Files committed (explicit paths)

- lib/smalt/messaging/amqp/queue_store.ex
- scripts/bench/b4_messaging_ts.mjs
- scripts/bench/REGISTRY.md (b4 row flip SUSPECT-PERMANENT → ALIVE)
- docs/jira/v26.10.14/receipts/bench-04-messaging-ts.md (BK-B4R addendum)
- docs/jira/v26.10.22/receipts/bkb4r-sender-link.md (this receipt)
