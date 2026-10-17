# ARD/PRD — smalt 26.10.16 Terraform golden-path (V1)

Standing: PARTIAL_ALIVE — the acceptance ladder (T5) is specified below;
greens are receipt-gated and land in
`docs/jira/v26.10.16/receipts/` and `docs/jira/v26.10.16/sdk-results/tf-plan.md`.

## Provenance and documented deviations

This file records the operator's acceptance direction for the
terraform-fixture golden path as dispatched to the v26.10.16 milestone-doc
lane. Two deviations from the operator's original text are documented and
pinned:

1. **azurerm version pin**: the original text specified `azurerm ~> 3.0`.
   The fixture pins azurerm to exactly `4.54.0` (with `azapi 2.4.0`)
   because azurerm 4.54.0 is the identity whose authority resolution,
   metadata-document parsing, and x509 handling the T5 ladder exercises —
   the 3.x line does not read `ARM_METADATA_HOSTNAME` or serve the same
   custom-cloud path. Fixture referent:
   `test/terraform_fixture/versions.tf` (`version = "= 4.54.0"`).
2. **KD error envelope**: the original text specified HTTP 422 for
   unclassifiable ARM failures. Smalt answers a typed **400** — this is
   the pinned ARM decision (typed 400 for unclassifiable/unrouted comp
   and query shapes; see the KD register's 400-class rows and the typed
   400 law in `docs/WIRE_PARITY.md`). The 400-not-422 shape is asserted
   in the data-plane tests and is not up for relitigation in a docs lane.

## Scope

Prove that unmodified standard Terraform plus the stock `azurerm` 4.54.0
provider drives the smalt substrate end to end — bootstrap, plan, apply,
state round-trip, destroy with zero residue — with no SDK or provider
forks and no hand-edited fixture input.

## Acceptance ladder (T5)

Five terraform stages, each with a mechanical pass criterion:

| Stage | Command | Pass criterion |
|---|---|---|
| T5.1 | `bash scripts/bootstrap_env.sh` | exit 0 (golden path env: bootstrap, certs, trust gate, hosts/pf status) |
| T5.2 | `terraform init` | exit 0; azurerm 4.54.0 / azapi 2.4.0 resolved |
| T5.3 | `terraform plan` | exit 0; "Plan: N to add" summary |
| T5.4 | `terraform apply` + `terraform plan -detailed-exitcode` | apply exit 0; second plan exits **0** (no drift: state/refresh round-trips through the emulator) |
| T5.5 | `terraform destroy` | exit 0; zero residue — `terraform plan` after destroy shows "No changes" on an empty graph, and no fixture-named resources remain in the substrate |

## Solved hops (each gated by a script, not prose)

| Hop | Mechanism | Gate |
|---|---|---|
| Authority redirect | `ARM_METADATA_HOSTNAME` (no scheme) → provider fetches `https://localhost:9444/metadata/endpoints?api-version=2022-09-01` and builds the full custom cloud env from it; STS stays on plaintext 9443 (`loginEndpoint = http://localhost:9443/` — azidentity accepts a plaintext authority only for localhost) | substrate metadata document carries the full 2022-09-01 schema (`name`, `resourceManagerEndpoint`, `resourceIdentifiers.microsoftGraphResourceId`) |
| TLS pinning | 9444 TLS twin pinned to TLS 1.2 + ECDHE-RSA-AES-GCM (OTP 28 ssl rejects X25519MLKEM768 key shares from recent Go clients) | `scripts/tf_smoke.sh` preflight + `just relay-env` |
| x509 compliance | Apple's strict evaluator (darwin Go always delegates) rejects CA:TRUE-as-leaf and CN=127.0.0.1 leaves; dev chain is CA `CN=smalt-dev-ca` + leaf `CN=localhost` (SAN `DNS:localhost, IP:127.0.0.1`) | `scripts/gen_dev_cert.sh` |
| Keychain trust | darwin Go ignores `SSL_CERT_FILE` (root_unix.go is non-darwin only); the CA must be trusted in the login keychain. `scripts/tf_trust_setup.sh` (`status`/`trust`/`retrust`/`untrust`) fingerprints both copies and routes dead-CA rot to `retrust`; a dismissed SecurityAgent dialog is a loud remediation, never a silent pass | `tf_trust_setup.sh status` exit 0 (step 3 of `bootstrap_env.sh`) |
| Hosts + port 443 | real Azure SDKs hit `https://management.azure.com:443` on loopback | `scripts/hosts_alias.sh` + `scripts/pf_redirect.sh` (status verbs inside `bootstrap_env.sh` steps 4-5) |

## Fixture inventory

- `test/terraform_fixture/` — single-RG golden path (rg + key vault +
  storage account), the T5 subject.
- `test/terraform_fixture_per_resource/` — per-resource-type probes
  (rg, storage, keyvault, cosmos, servicebus, eventhub), driven by
  `scripts/tf_plan_check.sh` (plan + apply + post-apply "No changes" per
  type; receipt to `docs/jira/v26.10.16/sdk-results/tf-plan.md`).

## Remaining registered divergences

- **Blob dot-form DNS limitation (documented)**: the storage-account data
  endpoint is dot-form (`<account>.blob.<host>`), which the loopback
  zero-touch stack (`hosts_alias.sh` aliases only
  `management.azure.com` / `login.microsoftonline.com`; `pf_redirect.sh`
  redirects port 443 only) does not route. Per-account blob hosts are not
  aliased — a storage-account apply against the fixture therefore cannot
  complete its data-plane round trip without additional per-account
  aliases; this is a documented limitation of the golden path, not a
  silent failure, and stays registered until a wildcard-DNS or
  path-form-parity close lands.
