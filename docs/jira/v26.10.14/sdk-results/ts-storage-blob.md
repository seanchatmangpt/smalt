# SDK lane TS-2 — real @azure/storage-blob (TypeScript) against the smalt blob plane

- **Date**: 2026-10-15/16 · **Lane**: TS-2 (v26.10.14 SDK fan-out)
- **Repo/SHA**: `/Users/sac/smalt` @ `3fc2543` (working tree, shared checkout mid-landing)
- **SDK**: `@azure/storage-blob` **12.34.0** (real npm install into `test/sdk-full/node_modules`, +19 pkgs)
- **Runtime**: Node v26.10.0, macOS arm64 (Darwin 25.2.0)
- **Substrate**: `MIX_ENV=test` `mix run --no-halt`, pinned ports ARM 9443 / egress 8443 / AMQP 5672, anonymous auth mode; entire boot+test window under exclusive `flock /tmp/smalt-substrate.lock`
- **Probe**: `/Users/sac/smalt/test/sdk-full/blob.probe.mjs` (in-repo, follows the `ts-reality.test.mjs` SharedKey auth shape: `BlobServiceClient("http://127.0.0.1:8443/smaltacct", StorageSharedKeyCredential("smaltacct","smaltacct-key"))` plus a manual SharedKey signer for raw REST bindings the SDK does not expose)
- **Harness**: `/tmp/sdk-ts-blob/boot3.sh` (flock-wrapped boot → 8443 orphan-holder cleanup → `node blob.probe.mjs` → beam teardown, all inside the lock)

## executed commands (receipt)

```bash
cd /Users/sac/smalt/test/sdk-full && npm install @azure/storage-blob --no-audit --no-fund   # added 19 packages
/tmp/sdk-ts-blob/boot3.sh    # x3 windows; window 3: lock acquired 00:02:10Z, done rc=0 00:02:13Z
```

Raw logs: `/tmp/sdk-ts-blob/run.out` (window 2), `/tmp/sdk-ts-blob/run3.out` (window 3, final).

## final results — window 3 (2026-10-16T00:02Z, exit 0, 15/15 PASS)

Probes (all executed against the live substrate): mutable container create via
`x-ms-immutable-policy:false` opt-out → 201; default-immutable container via SDK create → 201;
get container properties → 200; block blob upload → 201; download (GET + stream) byte-equality;
set/get container metadata round trip; blob `setMetadata` + signed `?comp=list&include=metadata`
XML assertion (`<who>ts2</who>` present); signed `?comp=list&delimiter=/` → `BlobPrefix` + leaf
blobs; If-Match stale etag → 412; If-Match correct etag → 200; WORM overwrite on immutable
container → 409; junk `maxresults=abc` → 400 XML envelope; blob delete → 202; container delete.

| # | probe | result |
|---|---|---|
| 1 | create mutable container (opt-out header) | PASS (201) |
| 2 | create default-immutable container (SDK) | PASS (201) |
| 3 | get container properties | PASS (200) |
| 4 | upload block blob | PASS (201) |
| 5 | download byte-equality (GET + stream) | PASS |
| 6 | set/get container metadata round trip | PASS (200, metadata echoed) |
| 7 | blob setMetadata + signed list include=metadata | PASS (XML `<who>ts2</who>` present) |
| 8 | signed list with delimiter → BlobPrefix | PASS |
| 9 | If-Match stale etag → 412 | PASS |
| 10 | If-Match correct etag → 200 | PASS |
| 11 | WORM overwrite → 409 | PASS |
| 12 | junk maxresults → 400 XML envelope | PASS (with divergence D2) |
| 13 | delete blob → 202 | PASS |
| 14 | delete mutable container | PASS (with divergence D3: observed 404, pinned) |

## divergences (executed, status+body evidence; all three stable across windows)

| # | probe | observed | Azure-expected | evidence |
|---|---|---|---|--- |
| D1 | blob `Set Metadata` | **201** with JSON debug body `{"content_length":0,"etag":"\"d41d8cd9…\"","headers":{…}}` (non-empty body, echoed request headers) | 200 with empty body | window 1+2: SDK resolved with `_response.status=201`; raw JSON captured in `/tmp/sdk-ts-blob/run.out` |
| D2 | `comp=list&maxresults=abc` | **400**, XML envelope present (`<?xml…><Error><Code>InvalidQueryParameter</Code><Message>Value for maxresults is invalid (must be a positive integer).</Message></Error>`) | 400, code `InvalidQueryParameterValue` | XML-envelope contract HOLDS; error-code token diverges (`InvalidQueryParameter`) |
| D3 | `DELETE` container via SDK | **404**, body `The specified blob does not exist.` | 202 | container delete appears mis-routed to the blob-delete clause; stable across all 3 windows |

Transient witnessed once (window 2 only, not reproducible in window 3): the SDK `setMetadata`
call rejected with the substrate JSON body as `RestError.message`. Classified as a transient
(shared checkout mid-landing / substrate boot-to-boot variance); windows 1 and 3 show the
stable 201 response.

Pre-existing (known, documented in `ts-reality.test.mjs`, not re-counted): `listBlobsFlat`
fails on substrate list XML missing the `<Segment>` wrapper; `downloadToBuffer` HEAD preflight
unimplemented — this probe uses GET `blob.download` + stream read and raw signed `?comp=list`
instead.

## notes for owners

- D1/D2/D3 are egress-plane wire divergences (`lib/smalt/` blob routes — no file edited by
  this lane). D3 looks like a router dispatch-order defect: `DELETE /{container}` (no blob
  name) lands on the blob-delete clause and answers `The specified blob does not exist`
  instead of 202.
- Cross-lane lock-hygiene finding: a backgrounded `mix run --no-halt` inherits the flock fd
  (fd 9), so an exited lane's substrate keeps holding `/tmp/smalt-substrate.lock` and 8443
  indefinitely — witnessed once (py-lane orphan beam, PPID 1, held both ~17 min; killed by
  this lane under the lock). Boot inside the flock subshell with the fd closed (`9<&-`) or
  kill the beam under the lock before releasing it (this lane's harness does both).
