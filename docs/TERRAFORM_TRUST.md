# Terraform TLS Trust Model

How Terraform (`azurerm` -> `azidentity`, or `terraform-provider-smalt`)
verifies the smalt substrate's dev TLS endpoint (`localhost:9444`), per OS,
and how to check/fix it.

## Background

The substrate serves a TLS twin of the ARM router on `localhost:9444`
(`ARM_METADATA_HOSTNAME=localhost:9444` makes `azurerm` `GET
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
verification goes through Apple `Security.framework`.

`scripts/smalt-tf` uses a **zero-dialog `DYLD_INSERT_LIBRARIES` trust shim**
(`scripts/trust_shim/smalt_trust_shim.dylib`) rather than mutating the
user's login keychain:

1. `smalt_trust_shim.dylib` interposes `Security.framework` trust evaluation
   (`SecTrustEvaluateWithError` / `SecTrustEvaluate`), pinning the exact
   leaf SHA-256 fingerprint (`SMALT_LEAF_SHA256`) and loopback SANs.
2. **Hardened-runtime constraint**: `terraform` strips `DYLD_*` from child
   plugin environments and Apple-signed/hardened binaries ignore
   `DYLD_INSERT_LIBRARIES`. `scripts/tf_provider_wrap.sh` therefore wraps
   ad-hoc-signed provider binaries in `.terraform/providers` with a small
   shell shim that re-exports `DYLD_INSERT_LIBRARIES`, `SMALT_LEAF_SHA256`,
   and `SMALT_CA_FILE` before `exec`ing the `.real` binary (and updates the
   run-local `.terraform.lock.hcl` `h1:` hash, restored cleanly on `EXIT`
   alongside unwrapping `.real` back).
3. **Optional keychain opt-in**: `scripts/tf_trust_setup.sh trust` (or
   `security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" .smalt/tls/ca-cert.pem`)
   is available as an explicit manual opt-in, never invoked automatically.

## Checking: scripts/tf_trust_check.sh

`bash scripts/tf_trust_check.sh` checks:

1. Cert material present (`.smalt/tls/{ca-cert,dev-cert,dev-key}.pem`,
   minting via `scripts/gen_dev_cert.sh` if absent).
2. **Linux**: `SSL_CERT_FILE` points at the CA + `openssl s_client -CAfile`
   handshake against `localhost:9444`.
3. **darwin**:
   - Either the zero-dialog `DYLD_INSERT_LIBRARIES` trust shim
     (`scripts/trust_shim/smalt_trust_shim.dylib`) is built and
     `SMALT_LEAF_SHA256` can be derived from `dev-cert.pem`, **or**
     `smalt-dev-ca` has non-zero trust settings in `login.keychain-db`.
   - `openssl s_client -CAfile` chain probe against `localhost:9444`.
   - `curl --cacert` `GET /metadata/endpoints`.
   - Last resort: dry `scripts/smalt-tf plan` exercising the real Go path.

Exit codes: `0` PASS, `1` FAIL, `2` UNREACHABLE (substrate not listening on
9444), `3` INDETERMINATE.

## See Also

- `scripts/smalt-tf` — env routing + `DYLD_INSERT_LIBRARIES` trust shim
- `scripts/tf_provider_wrap.sh` — provider wrapper for `DYLD_INSERT_LIBRARIES`
- `scripts/trust_shim/README.md` — shim design & codesigning constraints
- `scripts/gen_dev_cert.sh` — cert minting rationale
