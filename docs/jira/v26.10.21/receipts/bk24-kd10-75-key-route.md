# BK-24 — KD-10/KD-75 fix lane: real `PUT /keys/:name` route

**Standing:** ALIVE (both falsifiers met on the wire; typed negative legs; tests green)
Context: solo
Date: 2026-10-21
Lane build root: MIX_BUILD_ROOT=_build-bk24
Fix subject: `lib/smalt/egress/KvRoutes.ex` — `put "/keys/:name"` + `kv_key_put/3`
  (fix authored in-flight by a concurrent lane, snapshot-committed at dadf1e0;
  this lane adopted, compiled, bounced the substrate, and witnessed it live)

## Premise

BK-11 dispositions KD-10 + KD-75 as fix-and-witness on the shared PUT /keys/:name
face: "PUT /keys/{name}?api-version=7.x → 200 KeyBundle, create-or-replace;
unrouted PUT previously fell to the blob catch-all 400 MissingXMsVersion."
Both rows carried `# KD-COVERS: KD-10, KD-75` on the new route.

## Reproduce (BEFORE) — substrate pid 53160 (booted 19:34:22, pre-fix beam)

KD-15 challenge handshake performed (tokenless PUT → 401 with WWW-Authenticate →
bearer minted via `POST https://127.0.0.1:9444/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token`).

    $ curl -X PUT "http://127.0.0.1:8443/keys/bk24probe?api-version=7.4" \
        -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"kty":"RSA"}'
    <?xml version="1.0" encoding="utf-8"?><Error><Code>MissingXMsVersion</Code>... blob catch-all
    HTTP=400

## Fix adopted

`lib/smalt/egress/KvRoutes.ex` (committed dadf1e0):
- `put "/keys/:name"` → `with_valid_body` → `kv_key_put/3` (extracted from the
  POST /keys/:name/create arm — same store rows, same error arms).
- `# KD-COVERS: KD-10, KD-75` at the edit site.
- Compile: `MIX_BUILD_ROOT=_build-bk24 mix compile` → exit 0.

## AFTER — substrate pid 4232 (bounced 19:55:51, fix compiled in)

Fresh bearer (substrate bounce rotates the STS key — old token 401
SignatureVerificationFailed, re-minted):

    PUT /keys/bk24probe?api-version=7.4  ({"kty":"RSA"})   -> 200 KeyBundle, kid .../keys/bk24probe/392
    PUT /keys/bk24probe?api-version=7.4  (re-PUT, update face) -> 200, kid .../keys/bk24probe/456
    GET /keys/bk24probe?api-version=7.4                     -> 200, kid .../keys/bk24probe/456 (latest readback)

Both falsifiers met: KD-10 (create face, 200 + kid) and KD-75 (update face,
200 + readback). Versions accumulate (392 → 456); GET serves the latest.

## Negative legs (typed, Azure-exact shape)

    PUT kty oct-HSM-bogus -> 400 {"error":{"code":"UnsupportedKeyType","message":"kty oct-HSM-bogus is not supported"}}
    PUT no body           -> 400 {"error":{"code":"InvalidBody"}}
    tokenless PUT         -> 401 + WWW-Authenticate Bearer challenge (KD-15 handshake intact)

## Court gates

- `MIX_BUILD_ROOT=_build-bk24 mix test test/integration/bk19_kd10_kv_put_route_test.exs` → 1 passed, 0 failures
- `MIX_BUILD_ROOT=_build-bk24 mix test test/integration/kv_ec_create_test.exs test/integration/kv_crypto_face_test.exs test/integration/deletedkeys_purge_route_test.exs` → **Result: 10 passed**, 0 failures (POST /create face, crypto face, soft-delete purge face all unchanged)
- `python3 scripts/kd_flip.py` (read-only): KD-10/KD-75 FLIP-ELIGIBLE (witness
  bk30-kd-coherence-census.md postdates the covers-site mtime).

## Register flip decision (typed)

`kd_flip.py --apply` emits only CLOSED-SIMULATED — its own docstring says that
standing means "shim landed". This is a REAL route (lib/ route arm), not a
shim; flipping to CLOSED-SIMULATED would mislabel standing. KD-13 precedent
(real lifecycle witnessed on the wire) closes as CLOSED-WITH-RECEIPT via
registrar-style row edit. Both rows typed CLOSED-WITH-RECEIPT, citing
this receipt (mtime postdates the fix commit dadf1e0, so the flip is
receipt-gated). Done: KD-10 and KD-75 status cells now read
`CLOSED-WITH-RECEIPT (real put /keys/:name route ... witness
docs/jira/v26.10.21/receipts/bk24-kd10-75-key-route.md)` — replacing an
uncommitted CLOSED-SIMULATED flip that cited bk30-kd-coherence-census.md as
witness (that receipt is a census whose own text says "flip pending witness"
and names no kid, so it is not the falsifier witness). Post-flip:
`python3 scripts/kd_flip.py` reports KD-10/KD-75 `[CLOSED-WITH-RECEIPT]`,
FLIP-ELIGIBLE 0; both rows render 8 pipe-fields like the rest of the table.
