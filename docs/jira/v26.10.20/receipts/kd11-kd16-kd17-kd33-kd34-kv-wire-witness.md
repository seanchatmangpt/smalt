# KD-11 / KD-16 / KD-17 / KD-33 / KD-34 — KV face wire witnesses (fix-landed rows, live substrate)

**Standing:** **PASS** (wire witnesses on the live substrate, pid 57559, build 15:33Z 2026-10-20 — current HEAD code; lane K3, 2026-10-20)

All five rows' fixes predate this window (routes/engines in
`lib/smalt/egress/KvRoutes.ex` + `lib/smalt/data_plane/key_vault_actions.ex`); the
rows stayed OPEN unflipped. This receipt supplies the wire evidence per close condition.
All probes over the real wire with the KD-15 challenge handshake
(tokenless → 401 → bearer from the emulator STS `POST /organizations/oauth2/v2.0/token`).

## KD-11 (PATCH /keys/{name}/{version}) — fixed

- `PATCH /keys/k3probe` (latest) body `{"attributes":{"enabled":false}}` → **200**, attributes reflect `enabled:false`.
- `PATCH /keys/k3probe/<version>` body `{"attributes":{"enabled":true}}` → **200**, version row updated (`enabled:true`).
- Routes: `lib/smalt/egress/KvRoutes.ex` `patch "/keys/:name"` + `patch "/keys/:name/:version"` → `KeyVaultActions.update_key_properties/3`.

## KD-16 (versioned crypto + versioned kid) — fixed

- Create oct key → kid `https://localhost:8443/keys/k3probe/<version>` — the served kid carries the `/{version}` segment (CryptographyClient-constructible).
- `POST /keys/k3probe/<version>/encrypt` alg A256GCM → **200** (kid echoed, iv+tag+value).
- `POST /keys/k3probe/<version>/decrypt` → **200**, `value` byte-equal to the plaintext (`aGVsbG8=`).
- Routes: `post "/keys/:name/:version/:action"` (KvRoutes.ex:348) → `kv_crypto_dispatch` (encrypt/decrypt/sign/verify/wrapKey/unwrapKey, case-insensitive).

## KD-17 (SDK release_policy envelope) — fixed

- `POST /keys/k3pol/create` with SDK envelope
  `{"kty":"RSA-HSM","release_policy":{"contentType":"application/json; charset=utf-8","encodedPolicy":"<base64>","anyOf":[{"claim":"cberger is read-only","equals":true}],"data":true}}`
  → **200**; record `exportable:true`, release_policy stored verbatim.
- Grammar validation accepts anyOf/allOf/claim/equals structures (`validate_release_policy/1`, `policy_has_claim?/1` recursive walk) + allowed_operations spelling.

## KD-33 (top-level kid hoist) — fixed

- Create response carries `kid` at TOP LEVEL (`{"attributes":...,"key":{...,"kid":...},"kid":"https://localhost:8443/keys/k3probe/<version>"}`) — hoisted, not nested-only.
- GET /keys/:name and GET /keys/:name/:version render the same hoisted shape.

## KD-34 (percent-encoded api-version query key) — fixed by construction (Plug query decode)

- `POST /keys/k3probe/release?api%2Dversion=7.4` → gate passed (downstream SKR verdict, NOT `InvalidApiVersion`).
- Control: `?api%2Dversion=2099-01-01` → **400 InvalidApiVersion** — proves the percent-encoded key IS decoded and read (`Plug.Conn.Query.decode` decodes keys), the wire is parity-correct; api-version-pinned routing is safe.
- Control: missing api-version → **400 InvalidApiVersion**.

## Test receipt

`mix test test/data_plane` during the window: 52 tests, 1 failure —
`CosmosSqlRaiseTest` (concurrent-lane in-flight cosmos.ex, disclosed in
kd12-kv-rotationpolicy-put-body-witness.md; unrelated surface).

## Flip

`scripts/kd_flip.py` dry-run: KD-11/16/17/33/34 rows are fix-landed with wire witnesses
postdating their lib/ code (no shim-marker gap; the earlier fix lanes did not stamp
`# KD-COVERS` tokens on the route/engine code — dry-run classification below).

## Flip addendum (2026-10-20)

`# KD-COVERS` markers landed (KvRoutes.ex KD-11/16/17/33; egress_router.ex KD-34);
covers-map OK for all five. Verdict **FLIP-ELIGIBLE** with this receipt postdating the
markers (refreshed 2026-10-20T19:31Z, lane K3). `--apply` flips OPEN -> CLOSED-SIMULATED.
