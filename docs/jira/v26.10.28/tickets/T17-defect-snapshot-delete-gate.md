# T-17 — DEFECT: delete-blob-with-snapshots gate compiled but not firing

- status: CLOSED (2026-10-28): attribute-order root cause fixed, wire-receipted (409/202/include matrix), commit 474518c
- window: v26.10.28 · origin: parity lane defect (commit `8a6ce57` known-issues) · verdict-at-open: **DEFECT**
- size: **S** · depends-on: — · parity-leg: blob suite rows `blob-delete-under-immutable`, `blob-delete`, `blob-download-after-delete`

## current state (evidence)

`check_snapshots_on_delete/2` exists in `lib/smalt/data_plane/blob_storage.ex`
(delete_blob with-chain) and the compiled beam contains the atom
(source-verified `_build/test/lib/smalt/ebin/…BlobStorage.beam`), yet the
wire shows the gate NOT firing: probe sequence PUT → snapshot (201) →
sharesnapshot GET (200, snapshot exists) → DELETE returns **202** where
real Azure/Azurite answer **409 SnapshotsPresent**
(`parity/reports/mvsqkf7q-36121c/report.md`).

## suspected causes (check in this order)

1. A second delete path reaching the wire before the gated one — note the
   second `delete_blob` call site around `lib/smalt/egress_router.ex:3812`
   and any duplicate `delete` route shadowing the splat arm.
2. A `x-ms-delete-snapshots` header-shape mismatch in `header_map/1`
   (case normalization) making the option check mis-read.
3. The `:ets.match(@snapshot_table, {{blob_key, :_}, :_})` pattern against
   the actual key tuple shape (the {blob_key, ts} tuple is the KEY; the
   match object is the two-tuple).

## Definition of Done — the Azure developer's view

With `@azure/storage-blob` against smalt, deleting a blob that has
snapshots throws the same error your production code handles:
`(409) SnapshotsPresent` — unless you pass
`{ deleteSnapshots: "include" }`, in which case the blob AND its snapshots
are gone and both GETs 404 afterward. The parity suite's three
snapshot-delete rows flip to MATCH against Azurite, and the offline suite
plus the blob-worm gate stay green (no WORM regression).

## receipts required

Repaired parity run with the three rows MATCH; snapshot-delete matrix
receipt (no snapshot → 202; snapshot → 409; include → 202+gone; "only" →
base kept, snapshots gone).
