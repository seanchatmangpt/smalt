# Provider Court Receipt — 2026-10-31

- Subject: smalt azurerm-compatible provider (terraform-provider-smalt) vs smalt-on-kind ARM face http://127.0.0.1:9443
- Court: scripts/provider_court.sh, log dir /tmp/smalt-provider-court.IIXWx4
- Binary: 26667138 terraform-provider-azurerm
- dev.tfrc: dev_overrides attribute form, TF_CLI_CONFIG_FILE=/Users/sac/smalt/adapters/terraform-provider-smalt/dev.tfrc (~/.terraformrc untouched)
- Substrate: /metadata/endpoints 200, api-versions rg=2023-07-01

## Stage lines
```
PASS  stage1 build_install.sh PASS  stage2 tfrc.sh (attribute-form dev_overrides, ~/.terraformrc untouched) PASS  stage3 fmt/init/validate PASS  stage4 plan (1 to add) PASS  stage5 apply FAIL  stage6 falsifier1 (see /tmp/smalt-provider-court.IIXWx4/stage6-falsifier.log) (exit 1) FAIL  stage7 zero-drift re-plan (detailed-exitcode 2) (exit 1)
```

## Falsifier 1 (STS wire inspection)
- /healthz unauthenticated: 401 (expect 401); with STS-minted bearer: 404 (expect 200)
- STS token: 3-segment JWT, aud=https://management.azure.com: verified
- TF trace carries provider STS request + Bearer ARM call: verified
- destroy + residue-0 (no provider-court-rg in bearer list): verified

## Court exit
COURT_EXIT=1
