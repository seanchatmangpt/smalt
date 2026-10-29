# SJ-2 — Journal Reader (PROD-1)

**Standing:** ALIVE
Context: pair
Date: 2026-10-21
Module: `lib/smalt/storage/journal_reader.ex` (Smalt.Storage.JournalReader)
Court: `test/internal/journal_reader_court_test.exs` (15 courts)

## Subject

The sealed-segment reader for the PROD-1 journal, implemented against the
operator-reference mechanics (CRC-fail-closed, monotonic SeqID, sentinel-gated
discovery) and the frame protocol landed by SJ-1 (`Smalt.Storage.JournalSink`,
`lib/smalt/storage/journal_sink.ex`).

## Deliverables

- `discover_sealed_segments/1` — sentinel-gated discovery under `<dir>/sealed/`:
  a `.journal` is listed only when both `.seal` AND `.meta.json` exist.
  Active (unsealed) segments are never listed.
- `read_sealed_segment/1` — fail-closed check order, first failure wins:
  `.seal` → `.meta.json` → manifest sha256 over segment bytes → per-frame
  parse (truncated tail/frame, scoped CRC, monotonic SeqID strict +1).
  Every failure is a typed refusal; a corrupted byte is never admitted.
- Frame codec: reader implements the SMAL wire layout per the sink codec
  (`JournalSink.encode_frame/6`), CRC over body exactly as the writer scoped it,
  structural length check via typed `{:truncated_frame, reason: :bad_lengths}`
  — never a MatchError escape.

## Courts (Chicago: real writer, real bytes, no mocks)

- Clean parse: REAL `JournalSink` GenServer (append ×10 → seal) →
  `discover_sealed_segments/1` → `read_sealed_segment/1` round-trips all
  fields (seq_id, ts, event_type, table_id, key, payload).
- Sentinel law: `.wal` bytes without `.seal` → `{:not_sealed, path}`;
  `.seal` without `.meta.json` → `{:missing_meta, path}`; discovery lists
  only sealed segments, sorted.
- Tamper: 1-bit flips at payload / CRC field / seq field, each twice —
  first with the honest (stale) manifest → `{:manifest_mismatch, ...}`
  (refusal BEFORE any frame parse), then with a forged consistent manifest →
  `{:crc_mismatch, offset: 0}` (the per-frame gate itself refuses).
  1-bit flip → typed CRC failure, never admission, witnessed.
- Truncation: dangling partial header (< 8 bytes) → `{:truncated_tail, have: 3}`;
  frame cut mid-payload → `{:truncated_frame, needed: 58, have: 55}`-class;
  zero-byte segment with valid sentinels → `{:ok, []}`.
- Monotonicity: replayed seq and seq gap both → `{:seq_regression,
  expected:, got:}`.

## Evidence

```
$ MIX_BUILD_ROOT=_build-sj2 mix test test/internal/journal_reader_court_test.exs --seed 0
Result: 15 passed        # also seeds 12345 and 7: 15 passed each
$ MIX_BUILD_ROOT=_build-sj2 mix compile --warnings-as-errors | grep -c journal_reader
0
```

Cross-writer note: SJ-1's `JournalSink` landed mid-session; the round-trip
court starts the real writer GenServer (append + seal), so the cross-language
frame-contract direction writer→reader is witnessed on real bytes. The
reader-side frame encode was removed once the writer's codec landed — the
reader holds no parallel encode implementation (no O(N²) drift surface).

## Scope note (boundary)

Reader-only lane. No edits to `journal_sink.ex` (SJ-1 fixed its own binary
pattern compile error before any unblock was applied — no compile-freeze
disclosure owed). No shared infra, REGISTRY, or justfile edits. Build root
`_build-sj2` (lease; delete at integration).

## Falsifiers

- A tampered byte admitted as a valid frame fails the tamper courts.
- An unsealed segment parsed fails the sentinel courts.
- A truncated tail parsed as frames fails the truncation courts.
