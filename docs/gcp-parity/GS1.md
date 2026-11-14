# GS1 GCS dialect receipt

Standing: UNVERIFIED

Authored without mix/just/git (lane law). Coordinator must compile and run
`mix test test/gcp/storage_test.exs`; no result is claimed here.

## Files (all new, lane-owned)

- lib/smalt/gcp/storage.ex (pure core: buckets, objects, generations, preconditions,
  compose, resumable sessions, V4-shaped signed URLs, typed errors)
- lib/smalt/gcp/storage/server.ex (GenServer; serializes mutation so ifGenerationMatch is atomic)
- lib/smalt/gcp/storage/router.ex (Plug: JSON API, upload API media/multipart/resumable, XML
  path-style and host-style, Range, signed-URL verify)
- test/gcp/storage_test.exs (Chicago: real Server + Router via Plug.Test, no mocks, no sleep)
- docs/gcp-parity/GS1-gcs-census.md

## Wiring snippet (coordinator)

    # application.ex children:
    Smalt.GCP.Storage.Server
    # egress_router.ex, before the blob catch-all (match on host or /storage/v1, /upload/):
    forward "/storage/v1", to: Smalt.GCP.Storage.Router
    forward "/upload", to: Smalt.GCP.Storage.Router
    # host-style: when conn.host ends in ".storage.googleapis.com", call
    # Smalt.GCP.Storage.Router.call(conn, signing_key: Smalt.Config-provided-key)

## Divergences (not yet registered in KNOWN_DIVERGENCES)

State is in-process only (not Smalt.Store/journal; StoreTables registry is generated, so a
persistent port needs a pack ontology change). No object versioning (overwrite replaces),
no ACL/IAM, no auth, no pagination tokens, signed URL is HMAC emulator scheme not RSA.
