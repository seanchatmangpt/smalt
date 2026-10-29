# Receipt — KD-183 (KD-R17-2): point-read ignores the partition-key header

Standing: **CLOSED-WITH-EVIDENCE** (mint-then-close per KD-180 precedent).
Context: solo (wrap census, 2026-10-25).

- Surface: `lib/smalt/data_plane/cosmos.ex` — point-read path (docs GET by
  id): the `x-ms-documentdb-partitionkey` header was not consulted — a GET
  carrying a foreign pk answered 200 with the document body (leak surface);
  real Cosmos answers 404 on pk mismatch (S7.4 witness).
- Fix landed: same pk-match law as the write fence on the point-read path —
  header pk present and ≠ stored doc pk → 404 NotFound, no body (cosmos lane
  wave diff, `lib/smalt/data_plane/cosmos.ex`).
- Evidence (in-repo, real output): `test/data_plane/cosmos_pk_point_read_delete_test.exs`
  green in the wrap census + full-suite re-run at the landing SHA; upstream
  handoff `docs/kd_register_integration_2026-10-24.md` rows KD-R17-1/2.
- Falsifier: the pk-point-read court red, or an upstream court re-witnessing
  a cross-partition point-read 200.
