# r1 — T-13: OpenTofu plan parity vs terraform against the live substrate

- window: v26.10.28 · ticket: `tickets/T13-opentofu-compatibility.md` · date: 2026-10-28
- binaries: `tofu` 1.13.2 (scoop), `terraform` 1.17.0 (scoop)
- fixture: `scripts/tf_fixtures` (azurerm 4.54.0 / azapi 2.4.0, `metadata_host = "127.0.0.1:9444"`)
- substrate: canonical pinned-port boot (ARM 9443, TLS twin 9444), MIX_ENV=test

## run

```
tofu init      -> ok (providers from registry.opentofu.org; reuses the fixture lock)
tofu plan      -> Plan: 3 to add, 0 to change, 0 to destroy   (exit 0)
terraform init -> ok (rewrote lock hashes to registry.terraform.io; restored after)
terraform plan -> Plan: 3 to add, 0 to change, 0 to destroy   (exit 0)
```

Both engines planned the full fixture against the live substrate:
`azurerm_resource_group.smalt_fixture`, `azurerm_key_vault.smalt_fixture`,
`azurerm_storage_account.smalt_fixture` — identical plan summaries and exit
codes. Full outputs: `%TEMP%\tofu_plan3.log`, `%TEMP%\tf_plan2.log` on the
dev box; the summary lines are quoted above.

Env used (identical for both runs): `ARM_CLIENT_ID=1111…1111`,
`ARM_CLIENT_SECRET=smalt-sovereign-mock-secret`,
`ARM_TENANT_ID=0000…0000`, `ARM_SUBSCRIPTION_ID=1111…1111`.
`ARM_SKIP_PROVIDER_REGISTRATION` must NOT be set (the fixture pins
`resource_provider_registrations = "none"`; azurerm refuses both at once).

## Windows TLS note (the actual T-13 discovery)

Go-based IaC binaries ignore `SSL_CERT_FILE` on Windows (Unix-only code
path in crypto/x509), so the substrate's dev cert must be trusted via the
USER cert store, which needs no admin:

```
certutil -user -f -addstore Root .smalt\tls\ca-cert.pem
```

(The ca-cert.pem was exported from the live twin via
`openssl s_client -showcerts`; the twin's self-signed cert is stable across
connections — fingerprint-verified.) This step belongs in
`docs/how-to/how-to-run-on-windows.md` when the tofu recipe lands. The
repo's own tf lanes run on Linux/macOS with `SSL_CERT_FILE`/dylib shims
(`scripts/bench/c11_tf_loop.sh`), which is why this never surfaced before.

## verdict

T-13's DoD met at the plan tier: identical tofu/terraform behavior against
the substrate, zero substrate-side changes required. Remaining (optional,
next window): a `just tofu-plan-smoke` recipe wrapping the env above +
apply-tier receipt.
