# POSH-003: posh Azure ARM face via official SDKs

**DIALECT-SCOPED: dialect #1 (Azure ARM), consumes dialect #0 STS** — stamp
added by GAP-15 wave-2 doc migration (lane 15). Decision record:
[`../v26.10.31/00-unification-dialect-decision.md`](../v26.10.31/00-unification-dialect-decision.md).
Acceptance criteria below are unchanged.

## Task
posh exposes ARM operations backed by azidentity + ARM SDK (or raw azcore):
token mint (client_credentials vs smalt STS at {arm_endpoint}/{tenant}/oauth2/
v2.0/token), resource-groups CRUD, generic provider CRUD, containerApps.
Configuration: SMALT_ARM_ENDPOINT / SMALT_TENANT_ID / client secret env contract
identical to scripts/tf_cleanroom.sh lines 370-390 (ARM_METADATA_HOSTNAME etc.).
Plain-http localhost allowance must be honored (azidentity localhost rule).

## Acceptance
- posh CLI subcommand `arm probe` performs PUT/GET/DELETE of a probe resource
  group + containerApp against smalt on kind (http://127.0.0.1:9443) and prints
  a JSON receipt.
- Token cache: second call inside expiry reuses token (witness via smalt logs).

## Falsifier
A 401 path: invalid secret -> typed upstream error with status, not a crash; a
zero-state residue GET after DELETE returns empty.

## Landing receipt
LANDED 2026-10-30. `posh/internal/armclient/client.go` — STS mint, token cache,
turnstile-verify. Falsifier evidence: `posh arm probe` status=200 live witness
(C6 receipt 2026-10-30, this window) + typed exit-8 path.
