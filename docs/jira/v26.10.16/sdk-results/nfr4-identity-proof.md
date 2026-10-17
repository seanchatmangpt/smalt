# NFR-4: composite ETS baseline-identity proof — FAIL-CLOSED (orphans found)

Standing: **FAIL-CLOSED — real orphans, deterministically reproduced**

Lane: v26.10.16 validation (Agent 4, Ring 2, lane 503). Subject: `/Users/sac/smalt`
at main `fd9cfea` (uncommitted tree; validation lane, no `lib/` edits).

## Falsifier

Provision the FULL per-resource composite (RG + storage account + blobServices/
container + Key Vault + secret + Cosmos account + sqlDatabase + sqlContainer +
Service Bus namespace + queue + Event Hub namespace + hub) over the real
in-process `Smalt.ArmGateway.Router` (Plug.Test), tear down in reverse-topological
order, then assert `:ets.tab2list` strict identity across all 28 non-excluded
tables (sweeper-owned `:smalt_sb_locks` excluded per the approved exclusion list
in `test/smalt_ets_baseline_identity_test.exs`). Any post-destroy row is residue.

## Receipt (real command + output)

```
$ MIX_BUILD_ROOT=_build-lane503 scripts/fast_test.sh test/smalt_ets_composite_identity_test.exs
Running ExUnit with seed: 885566, max_cases: 32

NFR-4 composite ETS baseline-identity FAILURE: the composite lifecycle left residue.

Orphan dump (after vs baseline, differing tables only):
  smalt_cosmos_pk_meta
    baseline: []
    after:    [{{0, "etscompdb"}, %{"_rid" => "gC1nhr8f", "_self" => "/dbs/etscompdb", "_ts" => 1792178667, "id" => "etscompdb"}},
               {{1, "etscompdb", "etscompcol"}, %{"_rid" => "gC1nhr8fKn8k", "_self" => "/dbs/etscompdb/colls/etscompcol", "_ts" => 1792178667, "id" => "etscompcol", "partitionKey" => %{"kind" => "Hash", "paths" => ["/pk"]}, "uniqueKeyPolicy" => []}},
               {"etscompdb/etscompcol", %{"paths" => ["/pk"]}}]
    orphan keys: [{0, "etscompdb"}, {1, "etscompdb", "etscompcol"}, "etscompdb/etscompcol"]
  smalt_vault_secrets
    baseline: []
    after:    [{"ets-comp-secret", %{"attributes" => %{"created" => 1792178667, "enabled" => true, "updated" => 1792178667}, "id" => "https://www.example.com:8443/secrets/ets-comp-secret/7", "value" => "s3cret", "version" => "7"}}]
    orphan keys: ["ets-comp-secret"]

Finished in 0.1 seconds
1 test, 1 failure
```

Reproduced 3/3 consecutive runs — deterministic orphan set, deterministic
tables. The composite lifecycle itself (13 provision PUTs, 9 GET 200 spot
checks, 12 reverse-topological deletes, RG delete 202 → LRO poll → retention
eviction pass) all pass; ONLY the strict-identity fence fails.

## Findings — two orphan families (table + key pattern)

### 1. `smalt_cosmos_pk_meta` — 3 orphan rows per lifecycle

- `{0, <db>}` — database record (`do_create_db`, `lib/smalt/data_plane/cosmos.ex:103`)
- `{1, <db>, <coll>}` — collection record (`define_container`, cosmos.ex:171)
- `"<db>/<coll>"` — container pk-paths record (`container_key/2`, cosmos.ex:322)

Keys are bare db/coll names — NOT lowercased full ARM ids — so the RG
cascade's prefix sweep (`router.ex:671` sweeps `key <> "/"` over
`:smalt_resources`) and `handle_child_delete` (`router.ex:976`:
`Store.delete(:smalt_resources, key)` only) can never match them.
`handle_cosmos_child_put` (`router.ex:1036-1060`) seeds the data plane on PUT
but **no delete path** (ARM child delete, account delete, or RG cascade)
removes pk_meta rows. Every composite lifecycle leaks 3 rows per db+container
pair.

### 2. `smalt_vault_secrets` — 1 orphan row per lifecycle

- `"<secret-name>"` (bare secret-name key, no vault scoping)

`seed_data_plane_secret/5` (`router.ex:1126-1142`) cross-plane seeds
`Store.put(:smalt_vault_secrets, name, ...)` on ARM secret child PUT, but
`handle_child_delete` (`router.ex:976`) deletes only the ARM `:smalt_resources`
row — the data-plane row survives. The FR-6 vault DELETE sweep
(`vault_secret_sweep/1`, `router.ex:680-682, 2807-2811`) is capture-then-sweep
over swept ARM keys, so it only fires when the secret ARM child is still
present at vault/RG delete time; reverse-topological teardown (secret deleted
before vault — the real azurerm/TF order) always orphans the data-plane row.

## Why the existing baseline identity test did not catch this

`test/smalt_ets_baseline_identity_test.exs` used a single EventGrid topic —
its RG cascade fires with the topic ARM child still present, and no
cosmos/vault children were provisioned. The full composite with
reverse-topological teardown (release-realistic order) is the first surface to
exercise both orphan channels.

## Fix shape (for the owning lane; not applied by this validation lane)

- cosmos: remove `{0,db}`, `{1,db,coll}`, `"{db}/{coll}"` pk_meta keys on
  sqlContainer delete, sqlDatabase delete, and in the RG cascade via a
  capture-then-sweep keyed on the `databaseAccounts/<acct>/sqlDatabases/<db>`
  rel-path convention.
- vault: `handle_child_delete` must detect `Microsoft.KeyVault/vaults/secrets`
  child types and call `VaultData.drop_vault_secrets/1` with the trailing
  name; or route secrets through a dedicated delete route mirroring the FR-6
  sweep.

## Reproduction

```
MIX_BUILD_ROOT=_build-lane503 scripts/fast_test.sh test/smalt_ets_composite_identity_test.exs
```

Test artifact: `test/smalt_ets_composite_identity_test.exs` (lands with this
receipt; the strict-identity assert IS the fail-closed gate — it fails on the
orphan dump above and goes green when a fix lane closes both channels).
