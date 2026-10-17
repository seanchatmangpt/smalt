# Terraform Fixture — acceptance-test spec

Standing: **PARTIAL_ALIVE** until the T5 ladder greens on this fixture
(receipts land in `docs/jira/v26.10.16/receipts/` and
`docs/jira/v26.10.16/sdk-results/tf-plan.md`).

## Purpose

Minimal, unmodified-standard Terraform configuration proving smalt parity
with real Terraform behavior. Acceptance record for this fixture lives in
`docs/jira/v26.10.16/ARD-PRD-SMALT-26.10.16-V1.md`.

## Golden path

```sh
bash scripts/bootstrap_env.sh          # T5.1 — env + trust gate (exit 0)
just substrate-up                      # substrate (bootstrap_env does not boot one)
cd test/terraform_fixture
terraform init                         # T5.2 — azurerm 4.54.0 / azapi 2.4.0
terraform plan                         # T5.3 — "Plan: N to add"
terraform apply -auto-approve          # T5.4 — exit 0
terraform plan -detailed-exitcode      # T5.4b — exit 0 = zero drift
terraform destroy -auto-approve        # T5.5 — exit 0
terraform plan -detailed-exitcode      # T5.5b — exit 0, empty graph = zero residue
```

`scripts/smalt-tf` supplies the environment (`ARM_ENDPOINT`,
`ARM_METADATA_HOSTNAME`, credentials); this directory's `.tf` files stay
standard so smalt is exercised against unmodified Terraform input, which is
the whole point of the fixture.

## T5 ladder (pass criteria per stage)

| Stage | Command | Exit-code criterion |
|---|---|---|
| T5.1 | `bash scripts/bootstrap_env.sh` | 0 |
| T5.2 | `terraform init` | 0; providers resolved at exact pins |
| T5.3 | `terraform plan` | 0; "N to add" summary present |
| T5.4 | `terraform apply -auto-approve` | 0 |
| T5.4b | `terraform plan -detailed-exitcode` | 0 (no changes) |
| T5.5 | `terraform destroy -auto-approve` | 0 |
| T5.5b | `terraform plan -detailed-exitcode` | 0 (empty graph) |

Any non-zero exit other than the documented `tf_smoke.sh` SKIP (77,
registry unreachable) is a FAIL for the stage; the failure is loud and the
standing stays PARTIAL_ALIVE.

## Solved hops

| Hop | Mechanism | Gate script |
|---|---|---|
| Authority redirect | `ARM_METADATA_HOSTNAME` (no scheme; `ARM_METADATA_HOST` is NOT read) makes azurerm 4.54.0 fetch `https://localhost:9444/metadata/endpoints?api-version=2022-09-01` and build the whole cloud env from it; STS stays on plaintext 9443 (`loginEndpoint = http://localhost:9443/` — azidentity accepts a plaintext authority only for localhost) | substrate metadata document carries full 2022-09-01 schema |
| TLS pinning | 9444 TLS twin pinned to TLS 1.2 + ECDHE-RSA-AES-GCM (OTP 28 ssl rejects X25519MLKEM768 key shares) | `scripts/tf_smoke.sh`, `just relay-env` |
| x509 compliance | Apple's strict evaluator rejects CA:TRUE-as-leaf and CN=127.0.0.1 leaves; chain is CA `CN=smalt-dev-ca` + leaf `CN=localhost` (SAN `DNS:localhost, IP:127.0.0.1`) | `scripts/gen_dev_cert.sh` |
| Keychain trust | darwin Go ignores `SSL_CERT_FILE`; `scripts/tf_trust_setup.sh status/trust/retrust/untrust` fingerprints the keychain copy vs the on-disk CA and routes dead-CA rot to `retrust`; a dismissed SecurityAgent dialog is loud remediation, never a silent pass | `tf_trust_setup.sh status` exit 0 (step 3 of `bootstrap_env.sh`) |

## Contents

- `versions.tf` — `required_version >= 1.8.5`; `azurerm` pinned to exactly
  `= 4.54.0`, `azapi` pinned to exactly `2.4.0`; provider block entirely
  standard (`features {}`, `resource_provider_registrations = "none"`,
  fixed all-zero subscription GUID).
- `main.tf` — one resource group (`rg-smalt-fixture`, location
  `smalt-local`), one key vault (`kv-smalt-fixture`), one storage account
  (`smaltfixturestore`).
- `outputs.tf` — `rg_id`, `vault_uri`, `storage_account_id`.

## Legal note

This configuration is a fixture, not infrastructure. All GUIDs are all-zero
sentinels, `smalt-local` is not a real Azure region, and no secrets are
exported: the storage account's primary connection string is deliberately
omitted from outputs (exporting it would leak a credential);
`storage_account_id` is exported instead. Applying this configuration
against a real subscription would be rejected by Azure — the intended
behavior for a plan-only parity fixture on real Azure, and the golden path
above applies it only to the loopback substrate.

## Smoke runner: `scripts/tf_smoke.sh`

`bash scripts/tf_smoke.sh` boots the substrate, runs init/plan/apply/destroy
against this fixture, and prints a STEP/STATUS receipt. Exit codes: 0 all
passed; 1 preflight/substrate fault; 2 terraform step fault; 77
SKIPPED-NETWORK (registry.terraform.io unreachable).

Per-resource-type probes (rg/storage/keyvault/cosmos/servicebus/eventhub)
run via `scripts/tf_plan_check.sh` against
`test/terraform_fixture_per_resource/`; receipt:
`docs/jira/v26.10.16/sdk-results/tf-plan.md`.

## Provider mirror: `scripts/tf_provider_mirror.sh`

Populates `test/terraform_fixture/provider-mirror/` (gitignored) for offline
provider installs. Integrity + provenance model (2026-10-16, M7/M8 repair):

- **M7 — integrity re-validation**: `terraform providers mirror` is run on
  EVERY invocation; it validates each mirrored binary against registry
  checksums and re-downloads on mismatch (the old file-size-only probe could
  not detect a swapped/corrupted binary). When the connectivity probe fails,
  an existing mirror is trusted only loudly: receipts record mode
  `offline-trusted` (NOT re-validated this run) vs `online-revalidated`.
- **M8 — no committed rc**: there is NO committed `provider-mirror.rc` (it is
  gitignored; never commit one). `scripts/tf_mirror_env.sh` (sourced by
  `tf_smoke.sh` / `tf_plan_check.sh`) refreshes the mirror and generates the
  `TF_CLI_CONFIG_FILE` rc at run time into a `mktemp` path with the real,
  repo-relative-computed mirror location, so no absolute `/Users/...` path
  (username leak, non-portable) ever lands in the tree.

## Remaining registered divergences

- **Blob dot-form DNS limitation (documented)**: the storage-account data
  endpoint is dot-form (`<account>.blob.<host>`), which the loopback
  zero-touch stack does not route — `scripts/hosts_alias.sh` aliases only
  `management.azure.com` / `login.microsoftonline.com` and
  `scripts/pf_redirect.sh` redirects port 443 only. A storage-account apply
  cannot complete its data-plane round trip without additional per-account
  aliases. Documented limitation, not a silent failure; registered until a
  wildcard-DNS or path-form-parity close lands.

## Appendix: historical debugging record (2026-10-14, superseded as spec — kept as record)

The sections below were the fixture README while the hops above were being
solved. They are retained verbatim as the debugging record; the spec sections
above supersede them.

### Observed behavior (2026-10-14)

- Preflight and substrate boot work: `mix run --no-halt` binds 9443 within a
  few seconds when the tree compiles; the script tails the substrate log on
  failure.
- `terraform init` succeeds, downloading azurerm 4.54.0 / azapi 2.4.0 from
  registry.terraform.io (network required; blocked network yields exit 77).
- `terraform plan` FAILS with a substrate parity defect, not a script defect:
  the azurerm provider's client-credentials token request goes to
  `https://login.microsoftonline.com` (real Azure) instead of the loopback
  substrate, returning `AADSTS700038 ... is not a valid application
  identifier` for the all-zero client id. Evidence, from
  `TF_LOG=DEBUG terraform plan`:

      [DEBUG] POST https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token

  None of `AZURE_AUTHORITY_HOST`, `ARM_AUTHORITY_HOST` (http or https
  variants, both tested), or the substrate's
  `/metadata/endpoints?api-version=2015-01-01` `activeDirectoryEndpoint`
  (`https://login.smalt.local/`) redirect the token POST — azurerm 4.54.0
  keeps the default public-cloud AD authority for client-secret auth.
  Verified independently that the substrate itself is healthy:
  `POST http://127.0.0.1:9443/<tenant>/oauth2/v2.0/token` returns a signed
  HS256 JWT with `roles: [Contributor, Owner]`, and
  `GET /metadata/endpoints` returns 200 with the `*.smalt.local` endpoint
  map. The defect is upstream of the substrate, in the provider's authority
  resolution.

- `scripts/smalt-tf` additionally exports
  `ARM_SKIP_PROVIDER_REGISTRATION=true`, which azurerm 4.x rejects when the
  fixture sets `resource_provider_registrations = "none"` ("provider property
  `skip_provider_registration` cannot be set at the same time as
  `resource_provider_registrations`"). Until smalt-tf drops that export, the
  smoke script inlines the same environment minus that variable and calls
  `terraform` directly.

### Authority redirect solved (2026-10-14, lane: tf-local-auth)

`ARM_METADATA_HOSTNAME` (note: `ARM_METADATA_HOST` is NOT read by azurerm
4.54.0) makes the provider fetch
`https://<host>/metadata/endpoints?api-version=2022-09-01` (the `https://`
scheme is hardcoded in provider.go:
`environments.FromEndpoint(ctx, fmt.Sprintf("https://%s", metadataHost))`) and
build the whole cloud environment from it. The substrate therefore serves a
TLS twin of the ARM router on 9444 (`Smalt.Application` child, cert via
`SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE`, minted by `scripts/gen_dev_cert.sh`:
CA `CN=smalt-dev-ca` + leaf `CN=localhost` with SAN `DNS:localhost,
IP:127.0.0.1`, 800-day validity). The metadata document now carries the full
2022-09-01 schema (`name`, `resourceManagerEndpoint`,
`resourceIdentifiers.microsoftGraphResourceId`, `dnsSuffixes`,
`authentication.loginEndpoint = http://localhost:9443/` — azidentity accepts a
plaintext authority ONLY for the localhost host, so the STS stays on 9443) and
with that the provider advanced from `POST https://login.microsoftonline.com/...`
through, in order, each of these TF_LOG-experienced errors:

1. `retrieving metadata from endpoint "https://https://localhost:9444"` — do
   not include the scheme in `ARM_METADATA_HOSTNAME`.
2. `tls: insufficient security level` / client-hello `illegal parameter` —
   recent Go clients offer X25519MLKEM768 key shares the OTP 28 ssl app
   rejects; the 9444 listener is pinned to TLS 1.2 + ECDHE-RSA-AES-GCM.
3. `x509: “localhost” certificate is not standards compliant` — Apple's strict
   TLS trust evaluator (which darwin Go ALWAYS delegates to for system-pool
   verification) rejects a CA:TRUE self-signed cert served as a leaf, and a
   leaf with CN=127.0.0.1; use the CA + leaf chain.
4. `retrieving metadata from endpoint: 'name' was nil` — the 2022-09-01
   metadata document must carry `name`, `resourceManagerEndpoint` and
   `resourceIdentifiers.microsoftGraphResourceId`; without them
   `environments.FromEndpoint` refuses.
5. Endpoint reached: with the metadata document served, the provider parses
   the custom environment and the remaining hop is TLS trust of the dev CA.

### Remaining blocking hop (at record time): darwin TLS trust of the dev CA (macOS-only)

`SSL_CERT_FILE` does NOT work on macOS: Go's `crypto/x509` honors it only on
non-darwin Unix (`root_unix.go`); on darwin every system-pool verification
goes through Apple Security.framework, which needs the CA in keychain trust
settings. The single remaining command (run once per machine; if a GUI
authorization dialog appears, approve it):

```sh
security add-trusted-cert -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db .smalt/tls/ca-cert.pem
```

This step is now automated and gated by `scripts/tf_trust_setup.sh`
(status/trust/retrust/untrust; see the solved-hops table). On Linux,
`SSL_CERT_FILE=$ROOT/.smalt/tls/ca-cert.pem` (already exported by
`scripts/smalt-tf`) is expected to suffice with no keychain step.
