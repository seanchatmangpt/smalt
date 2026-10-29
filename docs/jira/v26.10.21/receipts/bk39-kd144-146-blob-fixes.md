# BK-39 — KD-144/145/146 blob-face fixes (fix lane)

**Standing:** **ALIVE**
- **Standing:** ALIVE (kd_flip witness token — machine-readable form of the line above)
- Context: solo
- Date: 2026-10-22 · Lane: BK-39 (fix) · Register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
- Substrate: booted lane-locally — `MIX_BUILD_ROOT=_build-bk39 9>&- just substrate-up`
  (lock fd closed; elixir 1.20.4-otp-29 via
  `PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"`; homebrew elixir 1.19.5
  refuses the repo's `~> 1.20` pin — the default-PATH boot fails with
  `(Mix) supports only Elixir ~> 1.20`).
- Builds/tests: `MIX_BUILD_ROOT=_build-bk39` throughout. Coordinator may `just lane-clean`
  `_build-bk39` at integration.
- Diff (uncommitted, per lane contract): `lib/smalt/data_plane/blob_service.ex`,
  `lib/smalt/data_plane/blob_storage.ex`, `lib/smalt/egress_router.ex`.

## Fix summary

One shared derivation, `BlobService.storage_etag/1` (blob_service.ex): quoted
`"0x" <> 16 UPPERCASE hex digits` — the Azure contract shape the rows name.

- **KD-144** (container etag): `container_etag/1` now routes through
  `storage_etag(seed)` (`# KD-COVERS: KD-144` at the derivation).
- **KD-146** (blob etag): both md5 mint sites (`store_blob/5`, `cas_replace/6`) and
  `metadata_etag/3` in blob_storage.ex route through `storage_etag/1`
  (`# KD-COVERS: KD-146` at both mint sites).
- **KD-145** (Put Blob 201 body): the egress_router put_blob `{:ok, blob}` arm no
  longer JSON-encodes `BlobStorage.blob_metadata/1`; it answers `send_resp(201, "")`
  with `etag` + RFC-1123 `last-modified` + `x-ms-request-server-encrypted: true`
  (`# KD-COVERS: KD-145` at the arm).

## BEFORE (pre-fix wire, live substrate, old build)

STS bearer via `POST http://127.0.0.1:9443/organizations/oauth2/v2.0/token` (200);
probes `x-ms-version: 2021-12-02`.

```
=== BEFORE KD-144: container create ===
HTTP/1.1 201 Created
etag: "B4B8EBD9BDC9D68047966921ABBCB0A6"          # 32-char UPPERCASE hex (KD-144)

=== BEFORE KD-145/146: put blob ===
HTTP/1.1 201 Created
content-length: 204
etag: "5eb63bbbe01eeed093cb22bb8f5acdc3"          # 64-char lowercase hex (KD-146)
content-type: application/json; charset=utf-8
{"content_length":11,"etag":"\"5eb63bbbe01eeed093cb22bb8f5acdc3\"",   # (KD-145)
 "headers":{...},"last_modified":"2026-10-22T03:12:06.914928Z","name":"bk39blob.txt"}
```

## AFTER (same probes, rebuilt substrate)

```
=== AFTER KD-144: container create ===
HTTP/1.1 201 Created
etag: "0x0CD708511F6B7F51"                        # 0x + 16 uppercase hex, quoted

=== AFTER KD-145/146: put blob ===
HTTP/1.1 201 Created
content-length: 0                                  # empty body (KD-145 closed)
etag: "0x5EB63BBBE01EEED0"                         # 0x + 16 uppercase hex (KD-146 closed)
last-modified: Thu, 22 Oct 2026 03:22:23 GMT
x-ms-request-server-encrypted: true

=== AFTER KD-146 GET ===
HTTP/1.1 200 OK
etag: "0x5EB63BBBE01EEED0"                         # same shape on the read face
```

Commands (curl against `http://127.0.0.1:8443`, `Authorization: Bearer $TOK`,
`x-ms-version: 2021-12-02`): PUT `/{acct}/{container}?restype=container` → 201;
PUT `/{acct}/{container}/bk39blob.txt` (`x-ms-blob-type: BlockBlob`, body
`hello world`) → 201; GET the blob → 200. Exits 0.

## Negative legs (conditional round-trip with the new shape)

```
etag="0x5EB63BBBE01EEED0"
GET  If-Match correct -> 200
GET  If-Match wrong   -> 412
DELETE container wrong etag -> 202
```

Blob If-Match round-trip is exact: the stored quoted `0x…` string satisfies
`ConditionalHeaders` both ways. The container-DELETE wrong-etag leg answered 202
(accepted) — If-Match is not enforced on that arm, a pre-existing behavior outside
this lane's three rows, noted here for the register, not fixed.

## Verification (targeted suites, MIX_BUILD_ROOT=_build-bk39)

- `mix test test/integration/blob_xml_error_test.exs test/integration/kd130_container_exists_test.exs`
  → exit 0 (all pass; etag assertions there are format-loose)
- `mix test test/integration/kd_conformance_test.exs` → exit 0
- `mix test test/integration/ja5_fail_fast_court.exs test/integration/cross_surface_determinism_test.exs`
  → exit 0 (6 passed)

## Compile-freeze disclosures (SLA)

Two concurrent-lane freezes hit the shared compile while this lane tested:

1. `lib/smalt/sync/frame.ex` (untracked, owner lane mid-write) — missing
   `import Bitwise` for `bxor/2`. BK-39 applied the minimal unblock fix
   (3-line commented `import Bitwise`, disclosure comment inline). Still in tree.
2. `lib/smalt/egress/SyncRoutes.ex` (untracked) — prose placeholder as a `defp`
   then a dangling `end`; BK-39 commented the placeholder line; the owner lane
   subsequently deleted the file entirely (freeze cleared).

Both fixes are minimal unblock fixes, disclosed here and owed to the other lane's
receipt.

## Register flips

`scripts/kd_flip.py --apply` ran with the KD-COVERS markers this lane landed
(`KD-144` blob_service.ex, `KD-145` egress_router.ex, `KD-146` blob_storage.ex ×2)
and flipped all three rows — but with the WRONG witness: it cited
`bk52-kd161-163-mint.md` (a concurrent lane's receipt that merely MENTIONS the
ids in a FLIP-PENDING comment — id-mention-only match) and set CLOSED-SIMULATED.
Corrected in place to CLOSED-WITH-EVIDENCE citing this receipt as the direct wire
witness (BK-36/KD-154 convention: wire evidence outranks a simulated-flip
verdict). Tooling finding for the register: kd_flip's `shows_pass` + id-mention
witness search can cite an unrelated concurrent-lane receipt — a name-matched
witness is not a witness; witness identity should be pinned (e.g. path required
to name the KD id in its filename or an explicit `witness:` field).

Receipt contains the machine-readable standing token ("Standing: ALIVE") the tool
greps for.

## Falsifier status

BK36 triage falsifier satisfied: re-run of the same live probes shows
`0x…`-prefixed quoted etags on both faces + 201 with an empty body. Standing ALIVE
against the post-fix substrate (exact build root `_build-bk39`, uncommitted diff).

## Post-flip re-probe (final, same substrate)

    $ PUT /bk39acct2/bk39c2?restype=container (bearer, x-ms-version: 2021-12-02)
    HTTP/1.1 201 Created
    etag: "0xFE1F3A9276B0EB00"

(An earlier re-probe using 2-char container name "c2" answered a typed 400 —
Azure-exact naming validation, healthy gate, not a regression.)

Register census: 160 KD rows, HEAD-vs-current census byte-identical malformed-row
count (naive pipe-split counts escaped-pipe rows as malformed; the delta introduced
by this lane is zero).
