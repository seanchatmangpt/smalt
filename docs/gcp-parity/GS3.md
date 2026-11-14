# GS3 Firestore Dialect Receipt

Standing: UNVERIFIED

Authoring lane only: no mix/just/git run; code uncompiled and tests unexecuted.

## Files

- lib/smalt/gcp/firestore.ex (engine; rows in :smalt_cosmos_docs, key {:gcp_firestore, p, path})
- lib/smalt/gcp/firestore/router.ex (Smalt.GCP.Firestore.Router, Plug.Router)
- test/gcp/firestore_test.exs (real Store + router; 10 tests incl. 12-way CAS race)
- docs/gcp-parity/GS3-firestore-census.md

## Wiring (shared file, not edited)

In the egress router (or Plug.Router mount point): `forward "/v1", to: Smalt.GCP.Firestore.Router`
(Firestore paths are `/v1/projects/{p}/databases/(default)/documents...`).
Needs Smalt.Store started (tables from Smalt.StoreTables); no new table required.

## Falsifiers / gaps

updateTransforms, cursors, batchGet, listCollectionIds, listen: UNSUPPORTED.
Next gate: `mix test test/gcp/firestore_test.exs`.
