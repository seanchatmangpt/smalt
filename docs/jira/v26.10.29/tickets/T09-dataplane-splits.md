# T09 — Data-plane splits: BlobStorage (3444) + Cosmos (3002) + KeyVault (2225)

- window: v26.10.29 · status: QUEUED · class: decomposition

## Why

Three data-plane engines each carry CRUD + auth/signing + parity quirks in
one module. Elixir idiom: contexts per aggregate, engines pure, plugs thin.

## Split plans

**BlobStorage** (`lib/smalt/data_plane/blob_storage.ex`):
- `DataPlane.Blob.Core` — container/blob CRUD + properties (pure engine).
- `DataPlane.Blob.Worm` — immutability policy/WORM invariants (the
  fail-closed gate surface lives here).
- `DataPlane.Blob.Leases` — lease/ETag/conditional headers.
- `DataPlane.Blob.Website` — static-website container face (already a
  distinct section at line ~3214).
- Plug layer stays thin; the existing blob courts gate byte parity.

**Cosmos** (`lib/smalt/data_plane/cosmos.ex` + sibling `cosmos_sql.ex`
1250 lines):
- `DataPlane.Cosmos.Accounts` / `.Databases` / `.Containers` / `.Docs`
  (CRUD faces), `DataPlane.Cosmos.Sql` — the SQL engine (move
  `cosmos_sql.ex` under the namespace; keep a `Smalt.CosmosSql` defdelegate
  shim for compat), `DataPlane.Cosmos.Auth` — the master-key
  string-to-sign.
- Cosmos ETag CAS gate (invariant gate) must stay fail-closed through the
  refactor — it is the non-vacuity court.

**KeyVaultActions** (2225):
- `DataPlane.KeyVault.Keys` / `.Secrets` / `.Certificates` / `.HSM`
  faces + `DataPlane.KeyVault.Auth` (challenge handshake KD-15). The KV
  corpus courts (real SDK challenge handshake) are the gate.

## Constraints

- Byte-identical wire behavior; no test edits; generated files untouched.
- Each split is one PR-sized diff, courts green before the next.
