# Census Store: Divergence-to-KD Mapping (W30-O)

Source: `error-census.jsonl` (W30-D, two runs 2026-10-21T16:44:05Z and
2026-10-21T16:45:24Z, 9 shapes per run over the smalt blob data plane vs
Azurite). Standing: PARTIAL_ALIVE — 9 shapes observed, 2 of them
run-unstable (see stability note).

**Row-assignment column is blank: W30-K (kd-registrar) owns the KD-row mint.**
Do not fill `KD row` from this lane; W30-K registers rows in
`KNOWN_DIVERGENCES.md` gated on a witness receipt postdating the evidence.

## Stability note

Two verdicts flipped between run 1 and run 2 — the census is not yet
run-stable for these shapes:

- `MissingContentLength`: run 1 MATCH (both 201), run 2 DIVERGE (smalt 201, azurite 400).
- `InvalidMetadata`: run 1 MATCH (both client-side transport refusal, status 0),
  run 2 DIVERGE (smalt 500, azurite 400).

Union table below carries per-run status for the unstable rows. W30-K should
treat these as UNSTABLE-EVIDENCE until a re-run (N>=3) stabilizes them.

## Mapping table

| # | Shape | smalt status/body | azurite status/body | Match (run1/run2) | KD row |
|---|---|---|---|---|---|
| 1 | MissingXMsVersion (GET, no x-ms-version) | 400 `MissingXMsVersion` "Missing required x-ms-version header, SAS token, or allowlisted host." | 200, body served (`0123456789`) | DIVERGE / DIVERGE | (W30-K) |
| 2 | ContainerNotFound (GET container) | 404 `ContainerNotFound` | 404 `ContainerNotFound` | MATCH / MATCH | (W30-K) |
| 3 | BlobNotFound (GET absent blob) | 404 `BlobNotFound` | 404 `BlobNotFound` | MATCH / MATCH | (W30-K) |
| 4 | ContainerAlreadyExists (PUT container) | 409 `ContainerAlreadyExists` | 409 `ContainerAlreadyExists` | MATCH / MATCH | (W30-K) |
| 5 | InvalidRange (GET bytes=1000-2000 on 10B blob) | 416, code emitted as `InvalidRange` in body only (null parsed code) | 416 `InvalidRange` | DIVERGE / DIVERGE | (W30-K) |
| 6 | MissingContentLength (PUT, no Content-Length) | 201, 0-byte blob, MD5 etag | run1: 201 / run2: 400 | MATCH / DIVERGE (UNSTABLE) | (W30-K) |
| 7 | InvalidBlobOrBlock (PUT ?comp=blocklist, unknown block) | 400 `InvalidBlockList` (with block-name detail) | 400 `InvalidBlockList` (no detail) | MATCH / MATCH | (W30-K) |
| 8 | InvalidQueryParameterValue (GET ?comp=bogus) | 400 `InvalidQueryParameterValue` (GAP(blob-comp-lease-absent)) | 200 (comp ignored) | DIVERGE / DIVERGE | (W30-K) |
| 9 | MissingRequiredHeader (PUT, no x-ms-blob-type) | 201 (type inferred as BlockBlob) | 400 | DIVERGE / DIVERGE | (W30-K) |
| 10 | InvalidMetadata (x-ms-meta header with invalid token) | run1: transport-level refusal (status 0, both sides) / run2: smalt 500 | run1: status 0 / run2: 400 | MATCH / DIVERGE (UNSTABLE) | (W30-K) |

## Summary

- Stable MATCH: 4 shapes (#2, #3, #4, #7)
- Stable DIVERGE: 4 shapes (#1, #5, #8, #9)
- Unstable evidence: 2 shapes (#6, #10) — re-run census N>=3 before minting KD rows
- Note: shape #10 in run 2 is a smalt-side 500 where azurite returns 400 —
  a server-side unhandled invalid-header case, distinct from the shared
  client-side transport refusal seen in run 1.

Evidence: `/Users/sac/smalt/popcorn_demo/azurite-spike/error-census.jsonl`
(census harness: `error-census.mjs`, W30-D receipt: `RECEIPT.md`).
