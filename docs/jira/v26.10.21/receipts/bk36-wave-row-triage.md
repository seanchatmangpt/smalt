# BK36 — Wave-minted OPEN row triage (verify lane)

**Standing:** **ALIVE**
- Context: solo
- Date: 2026-10-22 · Lane: BK36 (verify/triage) · Register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
- Substrate: already UP at lane start (`just substrate-status`: UP, pid 4232, lock FREE); no restart, fd-closed boot not needed.

## Verdict summary

| Row | Verdict | Evidence |
|---|---|---|
| KD-88 | OPEN (emulator-side re-verified clear) | EH ramp probe 40/40, errors=0 |
| KD-144 | OPEN (reproduces) | container ETag 32-char uppercase hex |
| KD-145 | OPEN (reproduces) | Put Blob 201 + JSON body |
| KD-146 | OPEN (reproduces) | blob etag 64-char lowercase hex |
| KD-153 | OPEN (reproduces, narrowed to status line) | namespace PUT 202 + full real-ARM LRO headers |
| KD-154 | **CLOSED-WITH-EVIDENCE** | location-less topic PUT → 201 (KD-156 gate fix covers the face) |

## Per-row detail

### KD-88 — EH checkpoint-store pump warm-up race (client-bound)

Emulator side re-verified live on current HEAD, warm substrate:

    $ SCVD_EH_HUB=bk36-eh-hub SCVD_CONCURRENCY=8 SCVD_SENDS=5 node scripts/bench/scvd_t18_eh_ramp.mjs
    2026-10-22T03:02:26.035Z EH n=40/40 ops/s=1212.1 p50=1.928ms p95=18.635ms p99=23.658ms errors=0 wall=33ms standing=PASS
    exit=0

40/40 deliveries, 0 errors on the @azure/event-hubs client over the live 5673
wire. Combined with the 2026-10-21 registrar edit's 330-frame decode replay
(`REPLAY-TOTAL frames=330 errors=0`, kd88-triage.md), the emulator surface is
cleared; the row's remaining scope is client-side only (@azure/event-hubs
6.0.4 / rhea 3.0.5 pre-send pump stall). Row updated in place with the fresh
probe citation; status stays OPEN (client-bound).

### KD-144/145/146 — blob face (all reproduce on current HEAD)

Live probes (warm substrate, STS bearer + `x-ms-version: 2021-12-02`):

    $ curl PUT http://127.0.0.1:8443/bk36acct/bk36container?restype=container
    HTTP/1.1 201 Created
    etag: "AD369F31AF6F2C652C402A65D89F97E4"          # 32-char UPPERCASE hex — not 0x… (KD-144)

    $ curl PUT http://127.0.0.1:8443/bk36acct/bk36container/bk36blob.txt (BlockBlob)
    HTTP/1.1 201 Created
    etag: "a79b1c9bfa920d860644eab19504371b"          # 64-char lowercase hex — not 0x… (KD-146)
    content-type: application/json
    {"content_length":10,"etag":"\"a79b…\"","headers":{…},"last_modified":…,"name":"bk36blob.txt"}   # non-spec body (KD-145)

    $ GET same blob → 200, etag identical format

All three still reproduce exactly as W32 observed. Stays OPEN with sharpened
Disposition: owning surface `lib/smalt/egress_router.ex`
(blob container-create / blob-PUT / storage etag rendering arms), falsifier =
BK36 probe re-run showing `0x…`-prefixed quoted etags / empty 201 body.
Note: the `x-ms-version` requirement gate answered a typed XML
`MissingXMsVersion` 400 on tokenless/versionless probes — Azure-exact
envelope, consistent with the KD-137/139 face, so the auth/version gates
around the divergent arms are healthy; only the three named arms diverge.

### KD-153 — SB namespace PUT status (reproduces, narrowed)

    $ curl PUT .../namespaces/bk36ns?api-version=2021-04-01  {"sku":{"name":"Standard"},"location":"eastus"}
    HTTP/1.1 202 Accepted
    azure-asyncoperation: http://127.0.0.1:8443/…/operations/<opid>
    location: same operation URL
    retry-after: 1

Still 202, not 200/201. Divergence narrowed: the LRO header face is real-ARM
exact (Azure-AsyncOperation + Location + Retry-After present; same-URL caveat
witnessed in t35-lro-contract.md, all 20 provisions 202 + headers), so the
residual divergence is the status line only. All 6 SDKs green per T24 —
SDK-tolerated. Stays OPEN, sharpened: owning surface
`lib/smalt/arm_gateway/router.ex` lro_type namespace-provision arm; next
action = status-code change keeping the async headers (low risk, low value).

### KD-154 — SB child-PUT location gate (NO LONGER REPRODUCES → CLOSED-WITH-EVIDENCE)

    $ curl PUT .../namespaces/bk36ns/topics/bk36topic  body {"properties":{"maxSizeInMegabytes":1024}}   (NO location)
    HTTP/1.1 201 Created
    (full topic echo, provisioningState Succeeded)

    $ control: same PUT WITH location → 201 (no regression on the loc face)

Reproduced 4× (topic + topic2 + control). Root: the KD-156 shape-gate fix
(`# KD-COVERS: KD-156`, `lib/smalt/graphlaw/validator.ex:237`, min_count
default 1→0; witness `docs/jira/v26.10.20/receipts kd156-sb-shape-fix.md`)
admits location-less child bodies on the same gate face this row names. The
covering shim carries only the KD-156 marker, so `kd_flip.py --apply` cannot
flip KD-154 (flip tool is KD-COVERS-gated); the row is typed
CLOSED-WITH-EVIDENCE by direct wire evidence per the wave-triage authority,
with the covering-shim disclosure inline. Registrar may later add a
`KD-COVERS: KD-154` co-marker to the validator shim and re-run kd_flip for
register hygiene; not done here (no lib edits this lane).

## Register integrity

Post-edit census: 157 KD rows; 153 at canonical 8-field shape, 4 pre-existing
escaped-pipe rows (lines 32/39/239/269 — identical set at HEAD, verified via
`git show HEAD:… > /tmp/bk36_kd_head.md` + same awk) — my edits introduced
zero malformed rows.

## Commands / exits

- `just substrate-status` → UP (pid 4232), lock FREE
- STS token: `curl POST /organizations/oauth2/v2.0/token` → 200 (token minted)
- EH ramp: `node scripts/bench/scvd_t18_eh_ramp.mjs` → exit 0, PASS
- Blob/SB curls: 201/201/200/202/201/201/400 as itemized above
- Register census awk: 157 rows, 4 pre-existing escaped-pipe rows (HEAD-identical)
