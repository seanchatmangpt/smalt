# v261019-envelope-iac-smoke — Phase 3 gate 3 upstream infrastructure smoke (IaC witness lane)

Standing: PARTIAL_ALIVE
Context: solo
Date: 2026-10-19
Lane: read-mostly witness lane; exclusive output = this receipt. No code edits landed.

## Scope executed

Full declarative lifecycle against the sovereign runtime using ONLY official
provider binaries (terraform 1.14.6 darwin_arm64, official hashicorp/azurerm
= 4.54.0 from the repo mirror), on lane block v5 (ports 39750-39755),
auth=enforce.

### 1. Substrate boot — PASS

```
$ bash scripts/substrate-ctl up --block v5 --auth enforce
{"block": "v5", "ports": [39750, 39751, 39752, 39753, 39754, 39755], "pid": 66835, "reused": false, "marker": "/tmp/smalt-substrate-state/markers/v5.boot.json", "auth": "enforce"}
RC=0
```

Corroborated by endpoint probes:

```
curl https://127.0.0.1:39754/metadata/endpoints --cacert .smalt/tls/ca-cert.pem
-> {"activeDirectoryEndpoint":"https://127.0.0.1:39754/",...}
curl http://localhost:39752/metadata/endpoints
-> {"activeDirectoryEndpoint":"http://localhost:39752/",...}
```

### 2. TF config (staged in /tmp/tf-v5-witness)

Combined families from `scripts/tf_fixtures_per_resource/` (rg + storage
account/container + key vault + servicebus namespace/queue), re-named v5-*
because each per-resource fixture reuses `azurerm_resource_group "probe"`.
Provider block mirrors `versions.tf` pins (azurerm = 4.54.0,
resource_provider_registrations = "none", all-zero tenant/subscription).
Routing: `scripts/smalt-tf` with `SMALT_TF_PORT=39752 SMALT_TLS_PORT=39754`
(ARM_ENDPOINT http://localhost:39752, ARM_METADATA_HOSTNAME 127.0.0.1:39754,
AZURE_AUTHORITY_HOST https://127.0.1:39754 — port-shifted https-authority
branch witnessed working).

### 3. Provider mirror bootstrap (repo-tree side effect, disclosed)

`scripts/tf_fixtures/.terraform.lock.hcl` did not exist (clean-room re-author
at 64f6099 deleted it; `tf_mirror_env_setup` and `smalt-tf` non-init verbs
both hard-require it). I regenerated it by running `smalt-tf init` in
`scripts/tf_fixtures/` once (untracked dir; `.terraform/` dir also created,
gitignored). This unblocks tf_smoke/tf_plan_check for every lane.

### 4. Trust: shim probe PASS, keychain untouched

```
$ go build trust_shim_probe + DYLD_INSERT_LIBRARIES=... probe -tls-dir .smalt/tls -want=pass
SEC-TRUST: pass (mode=real, SecTrustEvaluateWithError accepted the chain), url: https://localhost:50815
LEG OK: want=pass got=pass
PROBE_RC=0
```

Keychain trust: NOT required, not attempted (zero-dialog path).

### 5. init / plan — PASS

First two plan attempts FAILED typed (both mine to absorb, recorded because
they are real gate surface):

- ARM_METADATA_HOSTNAME unset → azurerm dialed default 9444 → `connect:
  connection refused`. Fixed by exporting SMALT_TF_PORT/SMALT_TLS_PORT.
- Provider binary was NOT injection-tolerant (mirror re-sign stage had
  crashed earlier on the missing fixture lock): `x509: "localhost"
  certificate is not trusted` despite shim active. Root cause chain:
  mirror re-sign crashed → mirror zips still HashiCorp hardened-runtime
  signed → DYLD shim blocked → provider rejects loopback chain. Re-ran
  `tf_mirror_env_setup` (completed: "re-signed 2 zip(s)"; SHIM-COURT marker)
  → re-init → plan PASS. This also documents that the re-sign stage is
  fail-open in its own script's crash path and fail-closed only via the
  wrapper's `[ -f lock ]` checks — a lane-external observation.

Final:

```
Plan: 6 to add, 0 to change, 0 to destroy.
PLAN_RC=0
```

### 6. apply — RC=1, two REAL parity divergences (typed)

Plan re-consistency note: applying the saved plan file failed
("Inconsistent dependency lock file" — the run-local wrap rewrites the
run-local lock each invocation); applying without a saved plan file works
and is what tf_smoke's ladder effectively does. Recorded as harness
friction, not a substrate defect.

Divergence A — ServiceBus queue (and storage container) PUT rejected for
missing `location`:

```
Error: unexpected status 400 (400 Bad Request) with error: InvalidResourceShape:
GraphLaw validation failure: A resource payload must carry exactly one location.
at location
```

Pinned by curl (official-wire PUTs):

```
PUT .../namespaces/<ns>/queues/<q> payload {"properties":{...}} (azurerm shape, no location)
-> RC=400 InvalidResourceShape "A resource payload must carry exactly one location."
PUT same, payload {"location":"smalt-local","properties":{...}}
-> RC=201, queue materialized
PUT .../storageAccounts/<acct>/blobServices/default/containers/<c> payload {} (azurerm shape, no location)
-> RC=400 same InvalidResourceShape
PUT same, + {"location":"smalt-local"}
-> RC=201, container materialized
```

Real Azure ServiceBus queue/container PUTs are child resources — the wire
contract omits `location`. The emulator's GraphLaw "exactly one location"
rule is over-applied to child resources (queue/container PUTs). Both
`azurerm_servicebus_queue` and `azurerm_storage_container` cannot land via
official provider. KD-CLASS: open, new, not in KNOWN_DIVERGENCES.md.

Divergence B — blobServices/default subresource 404:

```
Error: ... reading blob properties for Storage Account ... 404 with error:
ResourceNotFound: The Resource 'default' was not found.
```

Pinned by curl: `GET .../storageAccounts/<acct>` → 200; `GET
.../storageAccounts/<acct>/blobServices/default?api-version=2022-09-01`
→ 404. azurerm 4.54 requires this subresource at create AND at refresh
(destroy of the storage account is ALSO blocked by it). Effect: storage
account family is apply-blocked AND destroy-blocked via official provider.
KD-CLASS: open, new, not in KD register.

### 7. Read-back — DRIFT PRESENT (typed)

`terraform state list` after apply: rg, kv, sbns, stor (4 of 6; container
and queue never landed). Refresh plan (`plan -detailed-exitcode`):

```
Plan: 1 to add, 0 to change, 0 to destroy. (detailed-exitcode 1 w/ error)
```

Drift = the two divergence-blocked resources. The 4 landed resources read
back clean.

The 4 landed resources read back clean.

### 8. destroy — partially blocked, same divergence B

```
Plan: 0 to add, 0 to change, 3 to destroy.
Error: deleting Resource Group "rg-smalt-tf-v5": the Resource Group still contains Resources.
DESTROY_RC=1
```

`state rm azurerm_storage_account.stor` (RC=0) then destroy:
kv + sbns destroyed; rg delete refused while out-of-band children (queue +
container from my curl probes) remained; cleaned via curl DELETE
(container 200, queue already cascade-deleted 404, rg DELETE 202 cascaded)
and residue audit all 404 (rg/stor/kv/sbns GETs). Storage account deletion
was inside the rg cascade — the rg-level DELETE succeeded where the
provider-level destroy was blocked. Zero residue on the substrate (all
subsequent GETs 404).

## tf_smoke.sh full run — typed FAIL (exit 2), root-caused to a fixture edit by a concurrent lane

```
$ bash scripts/tf_smoke.sh            (also re-run shifted: SMALT_TF_PORT=39760 SMALT_TLS_PORT=39761)
preflight: terraform binary      PASS
preflight: fixture scripts/tf_fixtures  PASS
preflight: ports 9443/9444 free  PASS
shim-probe (Security.framework, pinned leaf) PASS (1825ms)
substrate bound 9443 <=30s       PASS (2196ms)
substrate bound 9444 <=30s       PASS (52ms)
provider mirror (receipt-revalidated) PASS
tf init (provider download)      PASS
token POST landed on substrate   UNKNOWN (5.7s then FAIL)
tf plan (3 to add)               FAIL (36ms)
================== TF SMOKE RECEIPT (exit 2) ==================
```

Exact error, deterministic (reproduced twice):

```
Error: retrieving metadata from endpoint "https://https://127.0.0.1:9444":
performing request: Get "https://https//127.0.0.1:9444/metadata/endpoints?api-version=2022-09-01": dial tcp: lookup https: no such host
```

Root cause isolated by A/B on my lane (same substrate, same provider):

- `metadata_host = "https://127.0.0.1:9444"` (current fixture form) →
  PLAN_RC=1, `https://https://127.0.1:9444` doubled scheme, FAIL.
- `metadata_host = "127.0.0.1:39754"` (bare hostname) → PLAN_RC=0,
  `Plan: 6 to add, 0 to change, 0 to destroy.` PASS.

azurerm 4.x `metadata_host` takes a bare `host[:port]`, not a URL;
azurerm prepends the scheme itself. The fixture file landed mid-run by a
concurrent lane (I read `tf_fixtures_per_resource/` at lane start; it did
not exist then). The `endpoints.tf` "AUDIT FINDING" claim ("metadata_host
is the upstream-standard surface") is directionally right but the VALUE
form is wrong (URL vs hostname). tf_smoke (fixture `versions.tf`) and any
consumer of `endpoints.tf` will FAIL until the value is host[:port] form
and the `ARM_METADATA_HOSTNAME` env (also set by smalt-tf) is not
compounded. smalt-tf sets ARM_METADATA bare `127.0.0.1:9444` which is
already sufficient — the HCL `metadata_host` line can simply be dropped,
or corrected to bare form.

## Lane-external findings for the registrar (not flipped by me)

1. NEW KD-class divergence: GraphLaw "exactly one location" over-applied to
   child-resource PUTs (ServiceBus queue, storage container) — azurerm
   4.54 sends no `location` on those PUTs; emulator 400s. Blocks
   azurerm_servicebus_queue + azurerm_storage_container families entirely.
2. NEW KD-class divergence: `blobServices/default` subresource 404 — blocks
   storage-account create/refresh/destroy via azurerm 4.54. (Related
   pre-existing rows KD-99..113 do not cover either. I minted no tokens.)
3. tf_smoke is currently red on the shared fixture `metadata_host` URL-form
   bug (concurrent lane's edit; A/B proof above). One-line fix in
   `scripts/tf_fixtures/versions.tf` +
   `scripts/tf_fixtures_per_resource/endpoints.tf`: bare `host[:port]`.
4. tf_smoke does not export SMALT_TF_PORT/SMALT_TLS_PORT to its smalt-tf
   child (local vars only) — shifted-lane tf_smoke targets 9443/9444. Typed
   here so the owner lane can decide export vs document-defaults-only.
5. Mirror re-sign stage crash-path: pre-existing, disclosed above.
6. Lane-external finding: `scripts/tf_fixtures/.terraform.lock.hcl` was
   regenerated this session (init bootstrap) — it is a runtime artifact
   required by tf_smoke/tf_mirror_env/smalt-tf; consider committing it (it
   is NOT covered by the fixture .gitignore patterns (`.terraform*/` matches
   the dir, not the lock file).

## Artifacts

- Config + state backups: /tmp/tf-v5-witness/ (scratch, gitignored /tmp)
- Run logs: /tmp/tf-v5-plan.out, /tmp/tf-v5-apply.out,
  /tmp/tf-v5-destroy.out, /tmp/tf-v5-destroy2.out,
  /tmp/tf-v5-refresh.out, /tmp/tf-smoke-run.out, /tmp/tf-smoke-run2.out,
  /tmp/mh-url.out, /tmp/mh-bare.out, /tmp/r.json probes
- Substrate torn down: `substrate-ctl down --block v5 --mode owner` RC=0
```
