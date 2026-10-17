# SDK lane TS-2 — real @azure/storage-blob (TypeScript) against the smalt blob plane

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `@azure/storage-blob` (from `test/sdk-full/node_modules`)
- **Runtime**: Node, macOS arm64 (Darwin 25.2.0)
- **Substrate**: lane333 persistent substrate, anonymous auth, egress/blob plane 39797, `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `test/sdk-full/blob.probe.mjs` with `SMALT_TS_EGRESS=http://127.0.0.1:39797`
- **Verdict**: 15/15 probes PASS, exit 0

## executed commands (receipt)

```bash
SMALT_TS_EGRESS=http://127.0.0.1:39797 node test/sdk-full/blob.probe.mjs   # exit 0
```

## results (2026-10-16, raw probe output)

```
PASS  create mutable container (x-ms-immutable-policy:false) 201
PASS  create default-immutable container via SDK 201
PASS  get container properties (immutable) 200
PASS  upload block blob 201
PASS  download equals uploaded bytes
PASS  set container metadata 200
PASS  get container metadata round trip
PASS  set blob metadata + signed list include=metadata
PASS  signed list with delimiter returns BlobPrefix
PASS  If-Match stale etag -> 412
PASS  If-Match correct etag -> 200
PASS  immutable overwrite -> 409
PASS  junk maxresults -> 400 XML envelope
PASS  delete blob 202
PASS  delete mutable container (divergence: 404 vs Azure 202)
15/15 passed
```

Note: the last row's 404-vs-202 container-delete divergence is the probe's own
pinned, pre-registered wire observation (carried in the probe; v26.10.14
receipt recorded the same shape as D3 on the router dispatch-order family).
All 15 probe rows executed green against the lane333 substrate.

## notes

- Run privately (egress remapped to 39797) — no canonical-port contact.
