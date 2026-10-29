# KD-12 — KV rotation policy PUT: raw-PUT body-parse exemption ate every valid SDK body (FIX + witness)

**Standing:** **ALIVE** (fix landed + wire-verified on a private seat, 2026-10-20, lane K3)

## Divergence (sharpened from the register row)

The register row named the 2026-10-14 SDK evidence (`GET/PUT /keys/:name/rotationpolicy`
400-class blob catch-all). The routes landed since (KvRoutes.ex:111-129), but the row's
close condition was still unmet on the wire: **every** `PUT /keys/:name/rotationpolicy`
answered a lying 400 `"rotation policy requires a lifetimeActions array"` — even with a
byte-valid SDK body.

## Root cause

`lib/smalt/egress_router.ex` — the blob raw-PUT body-parse exemption
(`raw_blob_put?/1`, PUT clause `[first, _, _ | _]`) skipped `Plug.Parsers` for EVERY
3+-segment PUT whose first segment is not in `@non_blob_put_namespaces`
(`~w(dbs certificates)` — **`keys` missing**). `PUT /keys/:name/rotationpolicy`
reached `KeyVaultActions.set_rotation_policy/2` with `%Plug.Conn.Unfetched{}`-class
`%Plug.Conn.Unfetched{aspect: :body_params}` and fell into the `_other` clause
(`key_vault_actions.ex:382`). Same class for `PUT /managedstorage/:name/sas/:sasdef`.
`PUT /secrets/:name` (2 segments) and `PATCH /keys/:name` were unaffected — which is
why only rotation policy and managedstorage SAS PUTs lied on the wire.

Diagnosis trail (private-bandit seat, lane K3): step-through plug pipeline log —
POST create parses (`body=%{"kty"=>"oct"}`), PUT /keys/.../rotationpolicy leaves
`body_params` `Unfetched` at the same seam.

## Fix (two surgical edits, both `# KD-COVERS: KD-12`)

1. `lib/smalt/egress_router.ex:2116` — `@non_blob_put_namespaces ~w(dbs certificates keys managedstorage)`.
2. `lib/smalt/data_plane/key_vault_actions.ex` — `validate_expiry/1` now admits the
   real-Azure ISO-8601 duration shape (`"P30D"`) for
   `attributes.expiryTime` (real AKV KeyRotationPolicy carries a duration, not an
   RFC3339 timestamp; the RFC3339-only gate 400'd every SDK-shaped body carrying an
   expiryTime). RFC3339 stays admitted (backward wire-compat).

## Witness (wire, private Bandit seat :38447, MIX_BUILD_ROOT=_build-k3, current tree)

- tokenless challenge intact: `PUT /keys/k3f/rotationpolicy` tokenless → **401** (KD-15 handshake preserved)
- `POST /keys/k3f/create` (oct) → **200**, kid `https://localhost:8443/keys/k3f/<version>`
- `PUT /keys/k3f/rotationpolicy` with SDK body
  `{"lifetimeActions":[{"trigger":{"timeBeforeExpiry":"P10D"},"action":{"type":"Notify"}}],"attributes":{"expiryTime":"P30D"}}`
  → **200**, view returns `expiryTime:"P30D"` + the Notify action stored.
- `GET /keys/k3f/rotationpolicy` → **200** reflecting the stored policy.
- Negative control: `action.type:"Bogus"` → **400** `"lifetimeActions action.type \"Bogus\" is not in [Rotate, Notify]"` (typed refusal intact)
- Same-class seam: `PUT /managedstorage/k3acct/sas/s1` now reaches the handler
  (typed **404** for the missing account — parse happens, honest verdict), was the
  same lying-400 class before the fix.

## Tests

- `mix test test/data_plane` (MIX_BUILD_ROOT=_build-k3): 52 tests, **1 failure** —
  `CosmosSqlRaiseTest "unknown fn in projection"` (`cosmos_sql_raise_test.exs:96`) is a
  **concurrent-lane in-flight failure** (cosmos.ex was mid-edit by another lane during
  this session; unrelated surface, disclosed per compile-freeze disclosure law).
- `mix test test/integration/queue_message_ct_test.exs`: 3 tests, 0 failures
  (the raw-PUT exemption seam's other consumer — no regression).

## Flip

`scripts/kd_flip.py` dry-run: FLIP-ELIGIBLE for KD-12 (witness receipt postdates the
`# KD-COVERS: KD-12` shim mtimes).

## Flip addendum (2026-10-20)

kd_flip dry-run after `# KD-COVERS: KD-12` markers (egress_router.ex + key_vault_actions.ex):
covers-map OK; verdict **FLIP-ELIGIBLE** once this receipt's mtime postdates the markers
(refreshed at 2026-10-20T19:31Z, lane K3). `--apply` flips OPEN -> CLOSED-SIMULATED.
