# DoD-11 Receipt — relay/environment bootstrapping

Lane: DoD-11 · Repo: /Users/sac/smalt · Date: 2026-10-15 · No commits (per dispatch).

## Files

- `justfile.d/11-relay-env.just` — new `relay-env` recipe (shebang recipe; emits an
  eval-able env block + AZURE_* mapping + endpoint-args cheat sheet).
- `scripts/dev_env.sh` — `DEFAULT_SDK_ROOT` moved from
  `/Users/sac/cai/athena/playground/node_modules` (out-of-repo) to the in-repo harness
  `$SMALT_REPO_ROOT/test/sdk-smoke/node_modules`; user override preserved (explicit
  `SMALT_SDK_ROOT` still wins and is still validated).
- `scripts/naming_sweep.sh` — UNCHANGED. My edit shifted no line numbers
  (`dev_env.sh:33` entry still pins the DEFAULT_SDK_ROOT line; sweep PASS 0 violations / 53 allowed).

## Spec delta (disclosed)

Task spec said `SMALT_SDK_ROOT=$PWD/test/sdk-smoke`; the `@azure` packages actually
live under `test/sdk-smoke/node_modules` (dev_env `--check` asserts
`$SMALT_SDK_ROOT/@azure`; lane-04's `sdk-census` recipe pins
`test/sdk-smoke/node_modules`). Defaulted to `test/sdk-smoke/node_modules` — still
in-repo, still the in-repo harness, and `--check` passes.

## Witnessed

- `just -f justfile.d/11-relay-env.just relay-env` → exit 0, block below.
  (Note: bare `just relay-env` from repo root is currently blocked by OTHER lanes'
  mid-edit justfile.d modules — 04-sdk-recipes.just and 03-cli-wiring.just had
  unindented continuation lines breaking just's parse of the whole include set. I
  applied the minimal compile-freeze-SLA unblock to 04 (dedent 3 `flock` lines,
  indent 8 `Application.put_env` continuation lines, content unchanged); 03 is
  another lane's file, left to its owner.)
- `eval` of the emitted block → `SMALT_SDK_ROOT=/Users/sac/smalt/test/sdk-smoke/node_modules`,
  11 `@azure` packages present.
- `bash scripts/dev_env.sh --check` → env validation PASSED
  (key 44 bytes, SDK root in-repo with @azure, repo, TLS material, doctor court);
  overall exit 1 solely from doctor `port-amqp` — a substrate is already listening
  on 5672 on this host (PID 16561, fan-out environment, pre-existing, not
  introduced by this lane).
- `bash scripts/naming_sweep.sh` → PASS: 0 violations / 53 allowed.
- Sanity: every value in the emitted block is 127.0.0.1 or under /Users/sac/smalt;
  no non-loopback hosts (grep-witnessed).

## Cross-lane notice for coordinator

- 04-sdk-recipes.just had a parse-breaking indentation defect; unblocked per SLA
  (disclosed above).
- 03-cli-wiring.just currently has the same class of defect (line ~71, unindented
  `from smalt_cli.gates import ... \` continuations) — owner should fix; bare `just`
  parse of the full justfile.d include set still fails until they do.

## Final env block (from `just relay-env`)

```bash
export SMALT_ARM="https://127.0.0.1:9443"
export SMALT_EGRESS="https://127.0.0.1:8443"
export SMALT_AMQP="127.0.0.1:5672"
export SMALT_SB_SHARED_KEY="$(openssl rand -base64 32)"
export SMALT_SDK_ROOT="${SMALT_SDK_ROOT:-<repo>/test/sdk-smoke/node_modules}"
export SMALT_TLS_CERTFILE="$PWD/.smalt/tls/dev-cert.pem"
export SMALT_TLS_KEYFILE="$PWD/.smalt/tls/dev-key.pem"
export SSL_CERT_FILE="$PWD/.smalt/tls/ca-cert.pem"
export AZURE_CLIENT_ID="smalt-emulator-client"
export AZURE_TENANT_ID="smalt-emulator-tenant"
export AZURE_CLIENT_SECRET="emulator-accepted"
export AZURE_AUTHORITY_HOST="https://127.0.0.1:9443/"
export AZURE_ARM_ENDPOINT="https://127.0.0.1:9443"
export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=smalt;AccountKey=$(openssl rand -base64 32);EndpointSuffix=smtt.local"
eval "$(scripts/dev_env.sh)"
```

The authoritative block is the recipe output itself (`just relay-env`); the
transcription above is for the receipt only.
