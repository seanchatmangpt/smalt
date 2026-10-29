# GLD-2 — Change-Data-Capture Incremental Ingestion Design Court

Milestone: v26.10.21 · Lane: GLD-2 · Standing: PASS (see
`receipts/gld2-cdc-court.md`)

## 1. Problem

Production SQL data does not arrive as one dump — it changes. The COLD-1
pattern ingests a full corpus once (cold path). What is missing is the warm
path: an epoch snapshot, then an append-only delta log, with the projected
ledger provably reflecting the delta exactly, replay idempotently, and the
delta durable across a process boundary.

## 2. The three-part pattern

### (1) Epoch snapshot (full ingest, COLD-1 pattern)

Epoch 1 ingests N rows in full. Each row becomes exactly one `ingest` event
in the OCEL event stream (one event per object, terminal until a later event
mutates it). The snapshot is the ledger state after replaying the ingest
events: `%{object_id => %{field => value, "__seq__" => event_id}}`.

Ledger state = `reduce(events, &project/2)` — a pure left fold. No storage of
its own; the fold is the snapshot.

### (2) Delta log (OCEL-native append-only event stream)

Deltas are OCEL events with `type ∈ {"insert", "update_before",
"update_after", "delete"}`. The OCEL-native representation of a mutation:

| SQL op | OCEL events | count |
|---|---|---|
| insert | `insert` | 1 |
| update | `update_before` + `update_after` (same tx id, adjacent) | 2 |
| delete | `delete` (terminal) | 1 |

Updates become two events because OCEL events are immutable observations: the
before-image is an observation of the prior state, the after-image observes
the new state, and both carry the same `"tx"` in attributes so the pair is
reconstructible as one logical transaction. Deletes are terminal: projection
removes the object and marks it `:deleted` in a tombstone set so a late
straggler event for a deleted id is detected, not silently absorbed.

Projection rules (pure `project/2`):

- `insert` → put object state
- `update_before` → recorded, does not change state (it *observes* state)
- `update_after` → overwrite state from the after-image
- `delete` → remove state, add id to tombstones

Event ordering = `(time, id)` lexicographic, matching `Smalt.Ocel.object_trace/2`
ordering. Replay = sort + fold.

### (3) Court

Epoch 1: 100 rows full ingest. Epoch 2 delta: 20 inserts, 10 updates
(→ 20 events), 5 deletes. Assertions:

1. **Exact delta reflection**: event counts (145 = 100 ingest + 20 insert +
   20 update-pair + 5 delete), every updated id's projected state equals its
   after-image at the latest timestamp, every inserted id present, every
   deleted id absent, no phantom rows (a state row with no producing event).
2. **Idempotent replay**: applying the same delta twice yields a byte-identical
   ledger (projection dedupes on event `id`; the second application is a
   no-op fold over already-seen event ids).
3. **Durability / journal**: `Smalt.Storage.Journal` (PROD-1) is checked via
   `Code.ensure_loaded?/1`; not landed in this tree → the leg records
   `{:journal, :pending, "PROD-1"}` (typed PENDING, not a fake pass) and the
   delta log is durably persisted to a real append-only segment file instead;
   a fresh reader replays the segment from disk and must reach the identical
   ledger digest. If PROD-1 lands, the leg auto-upgrades to exercising it.
4. **Non-vacuity tamper leg**: a mutated after-image value provably changes
   the ledger digest and fails the after-image assertion — the court RAISES
   if the tamper does not flip the outcome.

## 3. What this court is not

Not a wire/SDK parity claim, not a bench lane (no jsonl emitted), not a GxP
claim. It is a mechanism proof of the CDC incremental pattern over plain maps
in the `Smalt.Ocel` envelope shape.
