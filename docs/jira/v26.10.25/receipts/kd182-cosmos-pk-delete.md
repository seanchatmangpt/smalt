# Receipt — KD-182 (KD-R17-1): wrong-pk DELETE destroys cross-partition

Standing: **CLOSED-WITH-EVIDENCE** (mint-then-close per KD-180 precedent).
Context: solo (wrap census, 2026-10-25).

- Surface: `lib/smalt/data_plane/cosmos.ex` — `delete_doc/4`/`do_delete_doc/4`
  keyed only on `doc_key(db, coll, doc_id)`.
- Divergence: a DELETE carrying a foreign `x-ms-documentdb-partitionkey`
  answered 204 and really destroyed the document; real Cosmos answers 404
  ("Partition key provided in the header doesn't match the partition key of
  the document") and destroys nothing.
- Fix landed: the pk-match fence on the delete path (cosmos lane, Oct 23–25
  wave, `lib/smalt/data_plane/cosmos.ex`); fence asserts header pk vs stored
  doc pk → typed 404 NotFound on mismatch, matching the real-Cosmos message
  already pinned by the write fence (S7.3).
- Evidence (in-repo, real output): upstream security-claim courts S7.3–S7.5
  witnessed pre-fix 204-destroy; post-fix witness rides
  `test/data_plane/cosmos_pk_point_read_delete_test.exs` — green in the wrap
  census (1230/1250 summary line, this receipt's parent census.md) and green
  post-fix in the full-suite re-run at the landing SHA. Upstream handoff:
  `docs/kd_register_integration_2026-10-24.md` (scrubbed of off-repo paths).
- Falsifier: `mix test test/data_plane/cosmos_pk_point_read_delete_test.exs`
  red, or an upstream court re-witnessing a cross-partition DELETE 204.
