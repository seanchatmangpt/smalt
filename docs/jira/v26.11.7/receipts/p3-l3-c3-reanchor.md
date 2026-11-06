# P3-L3 — C3_COSMOS arcus re-anchor receipt

Standing: PARTIAL_ALIVE

- Lane: P3-L3 (C3 Cosmos re-anchor of the C1-C7 re-anchoring plan)
- Date: 2026-11-05
- Subject: `docs/compliance/C3_COSMOS.md` — arcus counterpart anchors
  appended for the C3 loci, per
  `docs/jira/v26.11.7/01-c1-c7-re-anchoring-plan.md` (dual-anchor form,
  KD-212 counterpart language).
- Repos: `/Users/sac/smalt` (doc append only), `/Users/sac/arcus` (read-only).

## Commands / evidence

- `find /Users/sac/arcus -name "cosmos_*.go"` → counterpart files confirmed
  on disk: `internal/dialect/azure/cosmos_auth.go` (58 lines),
  `cosmos_query.go` (323 lines), `table_odata.go` (258 lines).
- Both counterpart files read in full this session; every ANCHORED line range
  in the appended table was pinned from that read (not from the plan).
- `tail` after append → section landed at end of C3_COSMOS.md; no pre-existing
  byte of the doc was modified (append-only, verified by reading head of doc
  before and tail after; smalt anchors quoted in the new section are copied,
  originals untouched).

## Outcome

11 re-anchor rows (R1-R11):

- **7 ANCHORED** (with real line ranges): required headers (R1), session
  token format law (R2), rid grammar (R3), query POST wire law (R4),
  continuation token law (R5), 429 envelope law (R6), master-key auth law
  (R7), consistency echo (R8) — 8 rows counted as ANCHORED, of which R2/R3/R4/R5/R6
  carry a named UNSUPPORTED sub-half (durable LSN counters, doc-rid segment,
  SQL engine, ORDER cursor, throttle window).
- **UNSUPPORTED(counterpart-absent), loud**: R9 (cosmos_sql.ex AST
  translator — `cosmos_query.go:2-3` declares "NO SQL engine — wire law
  only"), R10 (partition_key.ex pk-header law — no Cosmos pk counterpart in
  `internal/dialect/azure/`; nearest neighbor `table_odata.go:50-70`
  `ExtractTableKeys` is Table-storage, pinned neighbor-only, never as
  anchor), R11 (etag CAS / status ladder / 413 / doc-id / 409 engine law).

## Notes

- The dispatch named `table_odata.go` as an anchor target; on-disk read
  refutes that as a Cosmos counterpart (it is the Table-storage OData law).
  Pinned as neighbor-only under R10 instead of a false anchor.
- No git operations (lane law). No lib/ or .go edits (lane lease).
- Falsifier: any ANCHORED line range failing to resolve against
  `/Users/sac/arcus/internal/dialect/azure/cosmos_auth.go` or `cosmos_query.go`
  as pinned; or any UNSUPPORTED row gaining a real counterpart without this
  section being updated in the same change.
