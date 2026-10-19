# s1_iac_chain — E2E IaC Chain Scenario

Fail-closed end-to-end scenario over the smalt sovereign substrate: substrate
boot, terraform parity smoke, raw-ARM resource chain, ResourceGraph query,
Sentinel audit ingestion, destroy + absence verification.

## Run

```bash
bash test/e2e/s1_iac_chain/scenario.sh
```

Exit 0 only when every step is PASS (BLOCKED-INTERACTIVE and SKIPPED-NETWORK
are honest non-PASS outcomes and fail the verdict, by design).

## Chain

1. **Boot** — env from `scripts/dev_env.sh`, dev TLS material, substrate on
   lane-local ports (41443 http / 41444 https / 40443 egress, 4672/4673 amqp)
   via `mix run --no-start -e 'Application.put_env(...)'`, pid file + EXIT-trap
   cleanup that also kills orphan beams on the lane ports. Boot retries up to
   3x when a sibling lane's beam sweep kills the fresh VM on the shared tree.
2. **Terraform parity** — delegates to `scripts/tf_smoke.sh` (it boots and owns
   its own substrate, so it must run BEFORE this scenario binds its ports).
   When tf fails on a darwin Go/x509 keychain-trust error, the scenario records
   `BLOCKED-INTERACTIVE` with the exact one-command fix and continues on the
   http surfaces:
   `security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db .smalt/tls/ca-cert.pem`
3. **Raw ARM chain** (independent of terraform):
   - STS bootstrap: `POST /oauth2/v2.0/token` (auth-exempt) -> Bearer for all
     later calls (bearer enforcement now active in both routers).
   - Fresh-store sanity: ResourceGraph must report 0 rows on a fresh substrate
     — detects sibling port collisions that would poison every later assert.
   - `PUT` RG + Key Vault + Storage Account with api-versions resolved from
     `Smalt.Registry.latest_version/1` (no hand-pinned versions).
   - `POST /providers/Microsoft.ResourceGraph/resources` — vault must appear
     (both `Microsoft.KeyVault` and the spec-literal `'microsoft.keyvault'`
     form; the engine's `startswith` is case-sensitive and the run reports
     both counts).
   - Sentinel: ingest an audit row (ledgerId/tenantId/subjectSha256/eventId/
     sha256Hash columns, resourceId = the vault id) through
     `POST /dataCollectionRules/.../streams/...`, then query it back via
     `POST /v1/workspaces/<dcr>/query` with `| where eventId == ...`.
   - Destroy: DELETE vault/storage/RG, then assert ResourceGraph no longer
     returns the vault.
4. Every step lands in a final fail-closed receipt table; verdict non-zero on
   any non-PASS.

## Known defects found by this scenario (cross-lane, not fixed here)

1. **LRO never reaches Succeeded on the wire.**
   `Smalt.ArmGateway.LRO.ensure_started/0` (lib/smalt/arm_gateway/lro.ex:79)
   `start_link`s the GenServer from the short-lived Bandit request process;
   when the 202 response completes, the link kills the server and the
   scheduled flip never fires. `GET /subscriptions/.../operations/:id` then
   returns `InProgress` forever (scenario step `PUT storage account (LRO)`).
   Direct `LRO.start_op/1` from a long-lived caller flips in <100 ms, which
   isolates the defect to the caller lifecycle, not the flip logic.
2. **ResourceGraph `subscriptions` filter always empty.** Store records
   written by `handle_resource_put/5` carry no `subscriptionId` field, but
   `Smalt.DataPlane.ResourceGraph.matching_resources/1` filters on
   `Map.get(r, "subscriptionId")` — any query with a `subscriptions` list
   returns `count: 0`. The scenario works around it (dedicated substrate) and
   documents the workaround inline.
3. **Bearer auth landed mid-session** (sibling lane): both routers now enforce
   `Authorization: Bearer` (HS256, STS-signed); the scenario bootstraps from
   `/oauth2/v2.0/token`.

## Environment notes

- Sibling lanes sweep stray beams and race for default substrate ports; the
  scenario therefore uses lane-local ports and retries boot.
- tf smoke needs the smalt-dev-ca trusted in the login keychain on darwin; the
  trust fix pops a SecurityAgent dialog, so the scenario never runs it.
