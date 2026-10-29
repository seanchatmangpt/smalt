# W30-S — SCVD second-backend proof (storage contract on Azurite)

**Standing:** **PASS** — the storage portion of the SCVD contract
(container create → blob PUT byte-equal → GET → delete, plus container
cleanup) ran 5/5 against Azurite (devstoreaccount1) on `127.0.0.1:10100`,
twice consecutively, exit 0 both runs, with the same byte-equal assertions
the smalt blob leg witnessed (W30-G dual-mode).

## Artifacts

- Harness: `/Users/sac/smalt/popcorn_demo/azurite-spike/scvd-azurite.mjs`
  sha256 `d15c5d30289f404129cba082abb5da39081dff9ecaafea1afa56d47b9c27da91`
- Result rows (spike-local): `/Users/sac/smalt/popcorn_demo/azurite-spike/scvd-azurite.jsonl`
  — 7 rows total: 5 FAIL then 2 PASS (honest full history, see Debug chain).
  NOT appended to `docs/jira/v26.10.20/bench/scvd.jsonl` — that corpus is
  smalt-host-only by definition; this row set documents the second-backend
  boundary at spike scope.
- Machine (`just bench-machine`):
  `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Verbatim passing runs

```
$ node scvd-azurite.mjs
[scvd-azurite] endpoint=http://127.0.0.1:10100/devstoreaccount1 x-ms-version=undefined
PASS scvd.container-create.201
PASS scvd.blob-put.201
PASS scvd.blob-get.byte-equal
PASS scvd.blob-delete.202
PASS scvd.container-delete
[scvd-azurite] standing=PASS row-> /Users/sac/smalt/popcorn_demo/azurite-spike/scvd-azurite.jsonl
exit=0
```

(Second run byte-identical output, exit=0; rows at 16:47:42Z and 16:47:47Z.)

## Environment

- Backend: azurite 3.37.0 (`azurite-blob --location ./azdata --blobPort 10100
  --skipApiVersionCheck`), PID 63245, left listening on 127.0.0.1:10100.
- SDK: @azure/storage-blob 12.34.0, devstoreaccount1 well-known dev key.
- The W30-N-booted azurite on 10100 went down mid-run (ECONNREFUSED row at
  16:46:32Z); per the W30-S task fallback this lane booted its own instance
  on the same port. No other lane's listener was evicted — the port was
  already free when this lane booted (verified via lsof before launch).

## Debug chain (pre-PASS failures, all receipted in the jsonl)

1. API-version refusal: SDK 12.34 hardcodes `x-ms-version: 2026-10-06`;
   Azurite 3.37.0 supports up to `2026-06-06` (`BLOB_API_VERSION` in
   `dist/src/blob/utils/constants.js:7`). Tried the client-side
   `{ version }` option — dead end: `Pipeline.getCoreClientOptions` passes
   only `{httpClient, requestPolicyFactories}` to the generated context, so
   the option is silently dropped. Server-side `--skipApiVersionCheck`
   (same fix W30-G used on 10000) resolved it. Harness carries an optional
   `XMS_VERSION` env pin for future use.
2. Devstore URL must include the account path
   (`http://127.0.0.1:10100/devstoreaccount1`); bare host gave
   "resource name contains invalid characters".

## Boundary

- `scvd.jsonl` stays smalt-host-only; second-backend rows live spike-local
  (documented in both the harness header and this receipt).
- Delete succeeded against Azurite (matches real Azure default containers);
  the smalt 409 WORM divergence on delete remains as flagged by W30-G for
  the KD registrar — not minted here.
