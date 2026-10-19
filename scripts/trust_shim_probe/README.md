# trust_shim_probe

Darwin trust verifier for the smalt dev TLS surface. Go + cgo
Security.framework (`SecTrustEvaluateWithError`) — the exact surface Go's
crypto/x509 uses on macOS (SSL_CERT_FILE is ignored on darwin; see
`docs/TERRAFORM_TRUST.md`).

## Build

```sh
bash scripts/trust_shim_probe/build.sh   # -> scripts/trust_shim_probe/trust_shim_probe
# the tf_* scripts build their own mktemp binary:
(cd scripts/trust_shim_probe && go build -o /tmp/probe .)
```

## Run

Default (shim) leg, with the trust shim env exactly as `scripts/tf_smoke.sh`
sets it:

```sh
ROOT=$PWD
DYLD_INSERT_LIBRARIES="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib" \
SMALT_LEAF_SHA256=$(openssl x509 -in "$ROOT/.smalt/tls/dev-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':') \
SMALT_CA_SHA256=$(openssl x509 -in "$ROOT/.smalt/tls/ca-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':') \
SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" \
  scripts/trust_shim_probe/trust_shim_probe -tls-dir "$ROOT/.smalt/tls" -want=pass
```

Live endpoint leg (the substrate's 9444 TLS twin):

```sh
scripts/trust_shim_probe/trust_shim_probe -addr localhost:9444 -want=pass  # CA trusted in keychain
scripts/trust_shim_probe/trust_shim_probe -addr localhost:9444 -want=fail  # no trust: typed UNTRUSTED (exit 0 = verdict matched)
```

Go's own system-verification path (no cgo orchestration):

```sh
scripts/trust_shim_probe/trust_shim_probe -sysroot -want=fail   # baseline: untrusted
```

Witness legs for the shim's anchor/settings interposes (need `SMALT_CA_FILE`):

```sh
SMALT_CA_FILE=$PWD/.smalt/tls/ca-cert.pem \
  scripts/trust_shim_probe/trust_shim_probe -anchor-probe -want=pass
SMALT_CA_FILE=$PWD/.smalt/tls/ca-cert.pem \
  scripts/trust_shim_probe/trust_shim_probe -settings-probe -want=pass
```

## Exit codes

- `0` — verdict matched `-want`
- `1` — mismatch (typed UNTRUSTED / unexpected trust)
- `2` — transport/usage failure (endpoint down, missing files)

## Flags

- `-want pass|fail` expected verdict
- `-tls-dir` smalt TLS material dir (default `.smalt/tls`)
- `-mode real|forge|evil` served chain: dev leaf / attacker self-minted leaf
  + public CA appended / non-loopback-SAN leaf
- `-addr host:port` dial a live endpoint and evaluate its served chain
- `-sysroot` real crypto/tls dial, RootCAs=nil (Go's own verdict)
- `-anchor-probe` / `-settings-probe` cgo witness legs (need `SMALT_CA_FILE`)
