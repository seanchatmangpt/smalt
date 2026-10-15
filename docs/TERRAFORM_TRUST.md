# Terraform TLS Trust Model

How Terraform (`azurerm` -> `azidentity`) verifies the smalt substrate's dev
TLS endpoint, per OS, and how to check/fix it.

## Background

The substrate serves a TLS twin of the ARM router on `localhost:9444`
(`ARM_METADATA_HOSTNAME=localhost:9444` makes azurerm `GET
/metadata/endpoints` there). Certificates are minted by
`scripts/gen_dev_cert.sh`:

- `.smalt/tls/ca-cert.pem` — self-signed root `smalt-dev-ca` (CA:TRUE, 10y)
- `.smalt/tls/dev-cert.pem` — CA:FALSE leaf for `localhost`/`127.0.0.1`
  (SAN DNS + IP, serverAuth, <=800 days)

The CA:TRUE-root + CA:FALSE-leaf chain is deliberate: Apple's strict
evaluator rejects a CA:TRUE self-signed cert presented as a TLS end-entity
(`x509: certificate is not standards compliant`).

## Per-OS trust model

### Linux

Go's `crypto/x509` honors `SSL_CERT_FILE` on non-darwin Unix. Setting
`SSL_CERT_FILE=$ROOT/.smalt/tls/ca-cert.pem` (done by `scripts/smalt-tf`)
is sufficient and **authoritative**. No keychain/system store involved.

### macOS (darwin)

Go's `crypto/x509` does **not** read `SSL_CERT_FILE` on darwin; every
verification goes through Apple Security.framework, which reads the
keychain trust settings. The dev CA must therefore be trusted in the login
keychain (user domain, no sudo).

Two non-obvious constraints:

- `security verify-cert` **cannot** be used as a gate: it returns exit 1
  even for a correctly user-domain-trusted CA.
- `openssl s_client -CAfile <ca>` proves only the served *chain* — openssl
  uses the supplied CAfile, not the keychain, so it says nothing about what
  the Go provider will decide.

The only authoritative darwin check is a real Go/azidentity run, i.e.
`scripts/smalt-tf plan`.

## Checking: scripts/tf_trust_check.sh

`bash scripts/tf_trust_check.sh` performs, in order:

1. Locate or mint cert material (`scripts/` or `.smalt/tls/`; mints via
   `scripts/gen_dev_cert.sh` if absent).
2. **Linux**: `SSL_CERT_FILE` points at the CA, plus an `openssl
   s_client -CAfile` handshake against `localhost:9444`. Result is clean
   PASS/FAIL.
3. **darwin**:
   - `security dump-trust-settings` — gates on actual trust settings for
     `smalt-dev-ca`, not mere presence. Measured 2026-10-14: the CA was in
     the keychain with zero trust settings and the Go provider still
     rejected the chain (`x509: certificate signed by unknown authority`),
     so `find-certificate` presence alone is not a valid gate.
   - `openssl s_client -CAfile` chain probe (proves chain, not trust),
   - `curl --cacert <ca> https://localhost:9444/metadata/endpoints`
     (endpoint live + chain),
   - last resort: a dry `scripts/smalt-tf plan` — the only check that
     exercises the actual Go/Security.framework path. If it fails for
     non-trust reasons (network/provider download), the verdict is
     INDETERMINATE.

Exit codes: `0` PASS, `1` FAIL, `2` UNREACHABLE (substrate not listening on
9444), `3` INDETERMINATE (fast checks passed, authoritative check could not
run non-interactively).

## The one-command fix (macOS)

```sh
security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" \
  .smalt/tls/ca-cert.pem
```

One interactive SecurityAgent approval; no sudo. `scripts/smalt-tf` runs
this automatically when the CA is absent from the keychain.

## See Also

- `scripts/smalt-tf` — env routing + automatic trust
- `scripts/tf_smoke.sh` — full init/plan/apply/destroy smoke
- `scripts/gen_dev_cert.sh` — cert minting rationale
