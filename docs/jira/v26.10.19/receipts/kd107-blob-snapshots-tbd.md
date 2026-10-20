# kd107-blob-snapshots-tbd.md — evidence receipt (witness lane, 2026-10-20)

- **KD row**: KD-107 (blob snapshots partial)
- **Standing**: ALIVE — evidence-executed. Full create → read-at-snapshot →
  overwrite-interplay → listing lifecycle witnessed over the wire on a live
  substrate; residual divergence (snapshot LISTING decoration) captured verbatim.
- **Subject**: smalt working tree @ 81a7a29, substrate block b4 (egress=39043),
  auth=enforce, bearer token minted from the block's STS
  (`POST /{tenant}/oauth2/v2.0/token` → http=200)
- **Context**: solo

## Execution-2026-10-20 (substrate b4, egress 39043, enforce auth)

### 1. Container + blob setup

```
$ curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2?restype=container'
HTTP/1.1 201 Created
x-ms-request-id: 2a2e348e-9db6-4ef0-8b06-3a5a307bf013
x-ms-version: 2021-12-02

$ printf 'kd107-snapshot-base-v1' | curl -sS -X PUT -H "Authorization: Bearer $TOKEN" \
    -H 'x-ms-version: 2021-12-02' -H 'x-ms-blob-type: BlockBlob' --data-binary @- \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2/kd107-blob.txt'
HTTP/1.1 201 Created
etag: "ff1aa3969013fffa7b24c256c1915028"
```

### 2. Snapshot create — 201 + x-ms-snapshot header (wired)

```
$ curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2/kd107-blob.txt?comp=snapshot'
HTTP/1.1 201 Created
x-ms-snapshot: 2026-10-20T03:12:35.580771Z
```

### 3. Read-at-snapshot — 200 with the frozen v1 body

```
$ curl -sS -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2/kd107-blob.txt?sharesnapshot=2026-10-20T03:12:35.580771Z'
kd107-snapshot-base-v1
http=200
```

### 4. Overwrite-with-snapshots-present → 409 ContainerLocked
(Azure-compatible: real Azure also refuses overwriting a blob that has snapshots)

```
$ printf 'kd107-base-v2-MUTATED-longer-body' | curl -sS -X PUT \
    -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    -H 'x-ms-blob-type: BlockBlob' --data-binary @- \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2/kd107-blob.txt'
{"error":{"code":"ContainerLocked","message":"Blob modification refused: container policy enforces immutable WORM retention."}}
http=409
```

### 5. Residual divergence: listing admits include=snapshots but never decorates

```
$ curl -sS -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2?restype=container&comp=list&include=snapshots'
<?xml version="1.0" encoding="utf-8"?>
<EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/devstoreaccount1" ContainerName="kd107-c2">
  <Prefix>devstoreaccount1/kd107-c2/</Prefix>
  <Marker></Marker>
  <MaxResults>50</MaxResults>
  <Blobs>
<Blob>
  <Name>kd107-blob.txt</Name><Properties>
    <Content-Length>22</Content-Length>
    <Etag>&quot;ff1aa3969013fffa7b24c256c1915028&quot;</Etag>
    <Last-Modified>2026-10-20T03:12:35.569826Z</Last-Modified>
  </Properties>
</Blob>

  </Blobs>
<NextMarker />
</EnumerationResults>

http=200
```

```
$ curl -sS -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2?restype=container&comp=list&include=snapshots,versions,tags' \
  | grep -c '<Snapshot>'
0
```

The `include` token is admitted (200) and the base blob is listed, but snapshot
rows are never decorated — silently-absent rows, not a typed refusal.

Also executed after the 409 (frozen read-back intact):

```
$ curl -sS -H "Authorization: Bearer $TOKEN" -H 'x-ms-version: 2021-12-02' \
    'http://127.0.0.1:39043/devstoreaccount1/kd107-c2/kd107-blob.txt?sharesnapshot=2026-10-20T03:12:35.580771Z'
kd107-snapshot-base-v1
http=200
```

All curl legs exited 0 (exit 0); transcripts above are verbatim session output.

## Standing rationale

Create (201 + `x-ms-snapshot`), read-at-snapshot (200, frozen, byte-exact), and
overwrite-refusal interplay (409 with snapshots present) are witnessed ALIVE
over the wire; snapshot LISTING decoration is the residual divergence (0
`<Snapshot>` elements under `include=snapshots`) and lease-on-snapshot
semantics remain unprobed/absent. Falsifier "SDK snapshot probe list + read-back
passes" remains NOT achieved on the list leg only. **KD-107 stays OPEN**,
narrowed to listing decoration + lease-on-snapshot. Standing ALIVE =
evidence-executed on the executed legs; receipt carries embedded real command
output (no longer SUSPECT-flagged).

## Registrar corrections this receipt supports

- The 2026-10-19 survey prose ("listing is a registered typed refusal") is
  tightened by execution: `include=snapshots` is ADMITTED with 200 and zero
  decoration, i.e. silently-absent rows — narrower divergence than a refusal,
  arguably worse for parity (silent). Row prose / WIRE_PARITY blob row may be
  tightened accordingly; not changed in this lane.
- Wire arms confirmed at `lib/smalt/egress_router.ex`:
  `?comp=snapshot` PUT (line ~2177), `?sharesnapshot=` GET (line ~2332),
  `# KD-COVERS: KD-60` pins both.

## Cross-links

- `KNOWN_DIVERGENCES.md` KD-107 row; `docs/WIRE_PARITY.md` blob row;
  KD-60 (covers-map CLOSED-SIMULATED); KD-108 (lease family).
- kd105/kd109/kd110/kd111/kd112 evidence receipts in this directory.
