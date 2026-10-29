# Receipt — w6aw: Blob soft-delete + versioning

Date: 2026-10-20
Lane: w6aw (wave-6)
Surface: lib/smalt/data_plane/blob_soft_delete.ex (NEW engine module), lib/smalt/egress_router.ex (3 additive wire arms), staged witness tmp/w6aw_witness.exs
**Standing:** PARTIAL_ALIVE
Context: solo

## What landed

Engine module Smalt.DataPlane.BlobSoftDelete (dedicated heir'd ETS tables):

- Delete retention policy: set_delete_retention_policy/2 parses the DeleteRetentionPolicy service-properties block (Enabled + Days 1..365; enabled-without-days or out-of-range is a typed 400 InvalidHeaderValue). delete_retention_policy/1 reads it back.
- Versioning flag: set_versioning_enabled/2 parses IsVersioningEnabled; versioning_enabled?/1 reads it back.
- Soft delete: intercept_delete/4 — when the policy is enabled, Delete Blob parks the blob record (deletion_time + remaining_retention_days) in :smalt_blob_soft_deleted AND removes the live row (real parity: soft-deleted blobs leave normal enumeration), answering the 202 face; :pass when no policy, so the normal hard delete runs.
- Undelete Blob: undelete_blob/3 restores the parked record via the real put path (fresh etag) and clears the parked row.
- Versioning: intercept_put/3 freezes the prior record as an immutable version (version_id = monotonic ms) before overwrites; list_versions/3 and get_version/4 retrieve prior versions by version-id.
- Count-only sweep: soft_delete_sweep/1 counts expired vs kept parked rows, never deletes.

## Wire arms (lib/smalt/egress_router.ex)

- Blob PUT splat arm: versioning intercept before the generic Put Blob fallback; new comp=undelete arm (registered in @blob_put_comps so unknown comps still 400).
- Blob DELETE splat arm: soft-delete interception before delete_blob (:pass falls through to hard delete).

## Witness (real output, replay: MIX_BUILD_ROOT=_build-lane-w6aw MIX_ENV=test mix run --no-start tmp/w6aw_witness.exs)

Final green run, EXIT=0, 16/16 legs true:

```
A_POLICY_SET=true
A_BAD_DAYS_400=true
B_CREATE_OK=true
B_SOFT_DELETE_202=true
B_SOFT_DELETED_STORED=true
B_LIVE_GONE=true
B_UNDELETE_OK=true
B_RESTORED_BYTES=true
C_VERSIONING_ON=true
C_OVERWRITE_OK=true
C_VERSIONS_COUNT=1
C_OLD_VERSION_BYTES=true
C_BY_VERSION_ID=true
C_LIVE_IS_V2=true
D_SWEEP_SHAPE=true
D_SWEEP_KEPT_1=true
W6AW WITNESS: DONE
```

Internal tier on the same tree: 48 tests, 0 failures.

## Falsifier

Re-run the witness with the live-row removal dropped from intercept_delete (B_LIVE_GONE would go false) or with the prior-record capture dropped from intercept_put (C_VERSIONS_COUNT would go 0) — a green run under either break would be vacuous.

## Residuals (typed, not silently skipped)

1. List Blobs include=deleted / include=versions XML rendering: engine rows exist; the list-XML arms are a named residual (follow-up lane).
2. Hard purge after retention: count-only sweep only; never deletes live data.
3. Batch sub-request deletes do not route through the soft-delete interceptor (batch delete stays hard delete under a retention policy).
