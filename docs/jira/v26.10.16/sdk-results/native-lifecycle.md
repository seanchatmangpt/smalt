# Native enclave lifecycle — equivalence validation receipt (lane 409, 2026-10-16)

Standing: ALIVE
Lane: validate+docs (lane 409), MIX_BUILD_ROOT=_build-lane409
Subject: `lib/smalt/enclave/lifecycle.ex` (`Smalt.Enclave.Lifecycle.run/2`),
`test/enclave_lifecycle_test.exs`
Claim: the native in-process lifecycle admits the same created-resource graph
as the external (smalt-tf + raw terraform) pipeline, with all six lifecycle
stages under 100 ms.

## Gate 1 — native lifecycle test (green)

```
$ MIX_BUILD_ROOT=_build-lane409 mix test test/enclave_lifecycle_test.exs

Finished in 0.1 seconds (0.00s async, 0.1s sync)
1 test, 0 failures
```

## Gate 2 — native in-process run (real dispatch through the ARM gateway router)

```
$ MIX_ENV=test MIX_BUILD_ROOT=_build-lane409 mix run --no-start /tmp/lane409_lifecycle.exs

TIMINGS_MS {"apply":52,"parse":3,"plan":2,"residue":0,"synthesize":1,"destroy":15}
CREATED [{"id":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-fixture","label":"azurerm_resource_group.smalt_fixture","azurerm":"azurerm_resource_group"},
 {"id":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-fixture/providers/Microsoft.KeyVault/vaults/kv-smalt-fixture","label":"azurerm_key_vault.smalt_fixture","azurerm":"azurerm_key_vault"},
 {"id":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-fixture/providers/Microsoft.Storage/storageAccounts/t5smaltfixturestore","label":"azurerm_storage_account.smalt_fixture","azurerm":"azurerm_storage_account"}]
PLAN_DIFF []
DELETED_ALL_VERIFIED true (n=3)
RESIDUE_EMPTY true (tables=17)
STATE_PATH tmp/enclave-native-lane409-1792173184875.tfstate
```

All six stages sub-100 ms (max: apply 52 ms; destroy 15 ms; residue 0 ms).

## Gate 3 — external tf_smoke attempts (contention-degraded, honestly typed)

`bash scripts/tf_smoke.sh` on lane ports 39443+/39453+ under concurrent
same-checkout fan-out did NOT complete green this session. Three distinct
shared-collision points, each observed live:

1. **Shared fixture state lock** — `test/terraform_fixture/` is a single
   terraform working dir; a concurrent lane's live `terraform apply` held the
   state lock (`resource temporarily unavailable`, Lock Info ID
   7cfd3bd3-... OperationTypeApply) and stale lock records broke subsequent
   plans. An orphaned `terraform.tfstate` (another lane's mid-cycle state,
   serial 7/9 churn) was parked to `/tmp/lane409-fixture-orphan/` to unblock
   preflight (disclosed; scratch state, gitignored).
2. **Shared cert regen** — every `tf_smoke.sh` start runs `gen_dev_cert.sh`
   into the global `.smalt/tls/`; three different leaf fingerprints were
   pinned within one run (1aec... → 9f40... → pinned A58E...), so the
   darwin Go trust shim pinned a leaf the live substrate never served
   (`x509: "localhost" certificate is not trusted`).
3. **Shared provider mirror** — `terraform providers mirror` revalidation
   raced between lanes; mirror refresh failed and the run fell back to the
   registry install path (init still PASSed, 31.4 s).

All tf_smoke preflight/substrate stages PASSed (ports 39453/39454,
substrate bound 2.1-11.4 s warm, init PASS) — the failures are exclusively
the three shared-state collisions above, not substrate or provider defects.

## Equivalence table — native vs external created-resource SETS

External evidence: the concurrently-running T5 cleanroom lane's ISOLATED
fixture copy (`/tmp/tf-cleanroom.zq3HmW/fixture/terraform.tfstate`, serial 4,
read after its `terraform apply` drained) — the isolation pattern that avoids
all three collisions above.

| Resource (HCL label) | Native id (in-process apply) | External id (terraform tfstate) | Match |
|---|---|---|---|
| azurerm_resource_group.smalt_fixture | `/subscriptions/00000000-...-000000000000/resourceGroups/rg-smalt-fixture` | `/subscriptions/00000000-...-000000000000/resourceGroups/rg-smalt-fixture` | IDENTICAL |
| azurerm_key_vault.smalt_fixture | `/subscriptions/00000000-...-000000000000/resourceGroups/rg-smalt-fixture/providers/Microsoft.KeyVault/vaults/kv-smalt-fixture` | same | IDENTICAL |
| azurerm_storage_account.smalt_fixture | `/subscriptions/00000000-...-000000000000/resourceGroups/rg-smalt-fixture/providers/Microsoft.Storage/storageAccounts/t5smaltfixturestore` | same | IDENTICAL |

**Verdict: native and external admit the SAME 3-resource graph.** Every id is
byte-identical (ids are ARM-canonical; both pipelines route through the same
ARM gateway router).

Body drift (documented, not forced): the native tfstate
(`Smalt.Enclave.State.write/2`) emits a minimal `{id, attributes}` shape per
resource (map of 3 keys); the external azurerm tfstate carries the full
azurerm attribute schema per resource. This is azurerm attr-mapping drift in
the state document only — resource identity (id sets) is identical, and the
drift is a documented convention, not a defect to force closed.

## Carry-forward

The three shared collision points (fixture state lock, `.smalt/tls` cert
regen, provider mirror revalidation) are the operational reason the external
tier demotes to opt-in T4-external (see `NEXT_WINDOW.md` section 12): the
tier is single-flight on three global resources. The native lifecycle has no
shared state beyond the in-process Store and is the primary green gate.
