# terraform-provider-smalt

A drop-in azurerm-compatible Terraform provider backed by the smalt ARM plane.
Same wire surface as `hashicorp/azurerm` (type name `azurerm`), but every
request lands on a smalt-on-kind cluster instead of Azure — same HCL, sovereign
plane. SPAF Tier 2 like `posh/`: protocol translation only, zero domain state.

## Architecture (one paragraph)

`main.go` serves the provider via `terraform-plugin-framework` under the
`registry.terraform.io/hashicorp/azurerm` address (must equal the import
address so dev_overrides type-name expectations line up). The `azurerm`
provider schema accepts azurerm-familiar attributes (`arm_endpoint`,
`subscription_id`, `tenant_id`, `client_id`, `ca_cert`, `features`, ...) and
`Configure` builds an `internal/provider.Client` that talks plain HTTP to the
smalt ARM gateway (default `http://127.0.0.1:9443`, overridable via
`arm_endpoint` or `SMALT_ARM_ENDPOINT`), minting bearer tokens from the smalt
STS (`/oauth2/v2.0/token`, client_credentials) with a 60s-before-expiry cache.
Resources are thin translations: `azurerm_resource_group` maps to
`PUT/GET/DELETE /subscriptions/{sub}/resourcegroups/{name}?api-version=2023-07-01`;
an optional `ca_cert` builds a custom TLS pool for the `https://127.0.0.1:9444`
TLS twin. `azurerm_client_config` exposes tenant/subscription/client/object
IDs. State is held only by Terraform; the provider keeps a cached token and
nothing else.

## Layout

- `main.go` — providerserver entrypoint (address pinned to `hashicorp/azurerm`).
- `internal/provider/` — provider schema, ARM `Client` (STS + bearer cache),
  `azurerm_resource_group` resource, `azurerm_client_config` data source.
- `scripts/dev_overrides.sh` — idempotent `dev.tfrc` writer.
- `dev.tfrc` — dev_overrides config pointing at this module directory.
- `examples/basic/main.tf` — copy-pasteable resource-group example.

## Quickstart (smalt-on-kind)

1. Boot the plane (see `k8s/README.md` for the full burn):

```bash
kind create cluster --config k8s/kind-config.yaml
docker build --target release -t smalt:local . && kind load docker-image smalt:local --name kind-smalt
kubectl create secret generic smalt-release-cookie \
  --from-literal=cookie="$(openssl rand -hex 16)" --save-config
kubectl apply -f k8s/smalt-backend.yaml
```

No port-forward needed: kind maps host 9443 → NodePort 30943
(`k8s/kind-config.yaml`), so `http://127.0.0.1:9443` reaches the plane
directly. Verify:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9443/metadata/endpoints
# expect 200 (auth-exempt surface)
```

2. Build the provider and wire dev_overrides (never touches `~/.terraformrc`):

```bash
cd adapters/terraform-provider-smalt
make install   # builds terraform-provider-azurerm into this dir + writes dev.tfrc
```

3. Point Terraform at `dev.tfrc` and run against smalt-on-kind:

```bash
cd adapters/terraform-provider-smalt/examples/basic
export TF_CLI_CONFIG_FILE=/Users/sac/smalt/adapters/terraform-provider-smalt/dev.tfrc
terraform init    # succeeds; expect the "Provider development overrides are in effect" warning
terraform plan    # expect: Plan: 1 to add
terraform apply   # creates azurerm_resource_group.rg on the smalt plane
terraform destroy # clean up the example resource
```

`dev_overrides` syntax note: Terraform >= 1.14 rejects the old labeled
block form (`dev_overrides "hashicorp/azurerm" { path = ... }` with
`may not have any labels`); the source-to-path mapping is an attribute of an
unlabeled `dev_overrides` block — exactly what `scripts/dev_overrides.sh`
writes. Do not pin a `version` under dev_overrides: a version constraint
makes the dependency lock file inconsistent and fails `plan`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 401 on `GET /healthz` | `/healthz` is bearer-gated; only `/metadata/endpoints` is auth-exempt | Probe `http://127.0.0.1:9443/metadata/endpoints` (always-200 auth-exempt surface) |
| 400 `InvalidApiVersionParameter` | Registry gate admits only `2023-07-01` for resourcegroups | Pin `api-version=2023-07-01`; provider already sends it (`rgAPIVersion`) |
| GraphLaw 400 not-admitted | Ontology gap — the target type is not in `Smalt.Registry` | Register the type in the smalt ontology; ARM pins refusal to 400, never 422 (`lib/smalt/arm_gateway/plug/common.ex`) |
| "no PEM certificates found" | `ca_cert` set but not a valid PEM | Append the kind dev CA (`.smalt/tls/ca-cert.pem`) contents |
| `provider failed to start` under dev_overrides | Binary not on `dev.tfrc` `path` or stale build | `make install` from the module dir; confirm `dev.tfrc` path equals the module dir |
| Plans hang / connection refused on 9443 | smalt-on-kind not up or NodePort mapping missing | Re-run the k8s burn; confirm `9443→30943` in `k8s/kind-config.yaml` |

## Status

v1 surface: resource groups + client_config data source. No release channel
(`version = "dev"`); consumed only via dev_overrides.
