# GLD-2 — CDC Incremental Ingestion Design Court

**Standing:** PASS · Context: solo · Date: 2026-10-21 ·
OTP 29 (Elixir via asdf shims) · Lane: GLD-2 · Milestone: v26.10.21

## Design

`docs/jira/v26.10.21/GLD-2-CDC-DESIGN.md` — three-part CDC pattern:
(1) epoch snapshot = full ingest as one `ingest` event per row, ledger is a
pure left fold; (2) delta log = append-only OCEL event stream where
update → `update_before`+`update_after` (paired by `"tx"`) and
delete → terminal `delete` event with tombstone; (3) court with exact-delta,
idempotency, durability, and tamper legs.

## Court output (real, exit 0)

```
$ elixir test/integration/gld2_cdc_court.exs
GLD-2 CDC COURT
  ok  epoch1 ledger holds exactly 100 rows
  ok  epoch1 event count == 100
  ok  event count == 145 (100 ingest + 20 insert + 20 update-pair + 5 delete)
  ok  ledger rows == 115 (100+20-5, no phantoms)
  ok  updated row-2 .. row-20 at latest timestamp == after-image   (10 rows)
  ok  inserted row-101 .. row-120 present                          (20 rows)
  ok  deleted row-57/64/71/78/85 tombstoned, absent from state
  ok  no phantom events
  ok  no phantom rows: every state row traces to a producing event
  ok  same delta applied twice == identical ledger digest
  ok  full replay with duplicated epochs == identical digest
  ok  delta replayed from durable segment == identical ledger digest
  PENDING  Smalt.Storage.Journal not landed (PROD-1); durability proven via real segment file replay
  ok  tampered delta provably changes ledger digest
  ok  after-image tamper flips projected state (court is not tautological)
GLD-2 COURT: PASS
ledger digest: a390a16485bd073fa809aa0b035967e7ab994e5665c8239c7f22a9a4ce10b783
events: 145  rows: 115  tombstones: 5
journal: {:journal, :pending, "PROD-1"}
EXIT=0
```

## Legs

1. **Exact delta reflection**: 100-row epoch-1 snapshot, then delta of
   20 inserts + 10 updates (20 paired events) + 5 deletes → 145 events,
   115 live rows (100+20−5), tombstoned deletes absent, updated ids carry the
   after-image at the latest timestamp, zero phantom rows (every state row
   traces to a producing event id).
2. **Idempotent replay**: delta applied twice, and full
   `epoch1++delta++delta++epoch1` replay, both yield a byte-identical ledger
   digest (`a390a164…b783`). Dedup is structural — already-seen event ids are
   no-ops in the fold.
3. **Durability — typed PENDING on PROD-1**: `Smalt.Storage.Journal` is NOT
   landed in this tree (`Code.ensure_loaded?` → false); the leg records
   `{:journal, :pending, "PROD-1"}` and does NOT fake a pass. Real durability
   is proven instead: the delta stream is written line-by-line to an actual
   append-only segment file, re-read from disk by a fresh reader, replayed —
   identical digest. If PROD-1 lands, the leg RAISES to force an upgrade
   rather than silently skipping.
4. **Tamper non-vacuity (two legs)**: mutating the first delta event changes
   the digest; mutating an after-image (`t-upd-1` value → 42) flips the
   projected state of `row-2`. The court raises if either tamper fails to
   flip.

## Honesty notes

- `MIX_BUILD_ROOT=_build-gld2` was allocated per lane contract but NOT used:
  the court runs under plain `elixir` (stdlib + `:crypto` only), same replay
  path as COLD-1, so no shared-tree `mix compile` was needed. No lane build
  root directory was created; nothing to clean.
- The first draft of the court file was generated corrupted (invalid Elixir)
  and was rewritten in full before any run — no run ever executed the
  corrupted draft.
- Not a bench lane: no jsonl emitted. Machine: macOS 26.2 arm64 (Apple
  Silicon), OTP 29.1.2 / Elixir 1.20.4-otp-29.

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"
elixir test/integration/gld2_cdc_court.exs   # exit 0 = PASS
```

No `Process.sleep` anywhere in the court.

## Artifacts

- Design: `/Users/sac/smalt/docs/jira/v26.10.21/GLD-2-CDC-DESIGN.md`
- Court: `/Users/sac/smalt/test/integration/gld2_cdc_court.exs`
- Receipt: `/Users/sac/smalt/docs/jira/v26.10.21/receipts/gld2-cdc-court.md`

## Standing

PASS — the CDC incremental pattern (epoch snapshot → OCEL-native delta log →
exactly-reflected, idempotently-replayable, durably-replayable ledger) is
ALIVE as a local mechanism proof. PENDING carried forward: PROD-1
`Smalt.Storage.Journal` integration (court auto-detects and forces the
upgrade when it lands).
