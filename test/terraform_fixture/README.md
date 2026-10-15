# Terraform Fixture

Minimal, unmodified-standard Terraform configuration proving smalt parity with
real Terraform behavior.

## What parity it proves

Running `just tf-plan-smoke` against this fixture exercises the full smalt
pipeline end to end:

1. Bootstrap discovery — Terraform finds the `.tf` files, the pinned provider
   requirements, and the provider block.
2. Token acquisition — credentials from `scripts/smalt-tf` environment
   variables (including `ARM_ENDPOINT`) are exchanged for a plan-time token.
3. Resource planning — the resource group, key vault, and storage account are
   planned the same way stock Terraform would plan them.

## Contents

- `versions.tf` — `required_version >= 1.8.5`; `azurerm` pinned to exactly
  `4.54.0` and `azapi` pinned to exactly `2.4.0`. The `azurerm` provider block
  is entirely standard: `features {}`,
  `resource_provider_registrations = "none"`, and a fixed subscription GUID.
- `main.tf` — one resource group (`rg-smalt-fixture`, location
  `smalt-local`), one key vault (`kv-smalt-fixture`), one storage account
  (`smaltfixturestore`).
- `outputs.tf` — `rg_id`, `vault_uri`, and `storage_account_id`.

## Legal note

This configuration is a fixture, not infrastructure. The subscription and
tenant GUIDs are all-zero sentinels, the location `smalt-local` is not a real
Azure region, and no secrets are exported: the storage account's primary
connection string is deliberately omitted from outputs (exporting it would
leak a credential); `storage_account_id` is exported instead. Applying this
configuration against a real subscription would be rejected by Azure, which is
the intended behavior for a plan-only parity fixture.

## Running

```sh
just tf-plan-smoke
```

`scripts/smalt-tf` supplies the environment (`ARM_ENDPOINT`, credentials);
this directory's `.tf` files stay standard so smalt is exercised against
unmodified Terraform input, which is the whole point of the fixture.

## Smoke runner: `scripts/tf_smoke.sh`

`bash scripts/tf_smoke.sh` boots the substrate, runs init/plan/apply/destroy
against this fixture, and prints a STEP/STATUS receipt. Exit codes: 0 all
passed; 1 preflight/substrate fault; 2 terraform step fault; 77
SKIPPED-NETWORK (registry.terraform.io unreachable).

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

### Remaining blocking hop: darwin TLS trust of the dev CA (macOS-only)

`SSL_CERT_FILE` does NOT work on macOS: Go's `crypto/x509` honors it only on
non-darwin Unix (`root_unix.go`); on darwin every system-pool verification
goes through Apple Security.framework, which needs the CA in keychain trust
settings. The single remaining command (run once per machine; if a GUI
authorization dialog appears, approve it):

```sh
security add-trusted-cert -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db .smalt/tls/ca-cert.pem
```

`scripts/smalt-tf` attempts this automatically on first run and gates on
`security find-certificate -c smalt-dev-ca` (NOT `security verify-cert`, which
returns 1 even for a user-trusted CA). Until that one approval lands, plan
fails at the metadata GET with `x509: certificate signed by unknown authority`
— with `TF_LOG=DEBUG` evidence that this is now the ONLY failing hop (the
provider reaches `https://localhost:9444/metadata/endpoints` and gets the
smalt metadata document; earlier hops are all green).

On Linux, `SSL_CERT_FILE=$ROOT/.smalt/tls/ca-cert.pem` (already exported by
`scripts/smalt-tf`) is expected to suffice with no keychain step.
