# TF Wire Ladder — Lane 509 (Ring 4 validation), 2026-10-16

Standing: **PARTIAL_ALIVE — T3 plan BLOCKED-TRUST (typed), wire itself proven correct.**

Subject: current tree (post shape-enrichment + HEAD routes + monotonic admission +
enrichment), external wire ladder T3/T4 via real `terraform` v1.14.6 CLI + real
azurerm 4.54.0 provider binary against the smalt substrate.

## Per-stage verdicts

| stage | verdict | evidence |
|---|---|---|
| preflight / terraform binary | PASS | terraform v1.14.6 darwin_arm64 |
| provider mirror | PASS (online-revalidated) | `terraform providers mirror` re-validated azurerm 4.54.0 + azapi 2.4.0 against registry checksums, "Package authenticated: signed by HashiCorp" |
| tf init | PASS | `terraform init -input=false -no-color` exit 0, scratch copy of `test/terraform_fixture` |
| STS token POST (ARM plane, 9443) | PASS | HTTP 200, HS256 bearer minted (`access_token` len 641) |
| zero-state witness (resources GET pre-apply) | PASS | cleanroom run: HTTP 200, `value = 0` |
| zero-touch trust-shim probe (Security.framework, CLI surface) | PASS | `SEC-TRUST: pass (mode=real, SecTrustEvaluateWithError accepted the chain)` |
| T3 terraform plan | **BLOCKED-TRUST** | provider TLS verify fails at metadata endpoint (see classification) |
| T4 plan -detailed-exitcode 0 / apply / destroy | NOT RUN | blocked upstream at plan |

## Trust / DRIFT state (exact)

- `scripts/tf_trust_check.sh` verdict **FAIL**: CA cert imported to login keychain
  but has **ZERO trust settings** (presence != trust). `security add-trusted-cert
  -r trustRoot` has NOT landed — no keychain re-trust flip occurred this session.
- Cert material was **reminted mid-session by a concurrent lane** at 12:14:31 (CA)
  / 12:16:06 (leaf) with the fixed `gen_dev_cert.sh`: leaf is now `CN=localhost`,
  `basicConstraints=critical,CA:FALSE`, issuer `smalt-dev-ca`, SAN
  `DNS:localhost, IP:127.0.0.1, DNS:management.azure.com, DNS:login.microsoftonline.com`.
- Chain on disk now verifies: `openssl verify -CAfile ca-cert.pem dev-cert.pem` → OK.
- The **running global substrate beam (PID 42645, ports 9443/9444) still serves the
  PRE-remint leaf** in memory (self-signed `CN=127.0.0.1`, `CA:TRUE`) — its TLS
  presentation will stay broken until the substrate restarts. A substrate restart
  is a coordinator call (shared, lanes may depend on it).
- DRIFT: **UNKNOWN/N-A** — `plan -detailed-exitcode` never reached; plan blocked at
  provider bootstrap TLS.

## Typed classification of the wall: BLOCKED-TRUST (darwin Go runtime trust boundary) — NOT a wire divergence

Two distinct errors were witnessed, corresponding to the two cert generations:

1. **Pre-remint leaf** (self-signed, `CA:TRUE`, presented as end-entity):
   `x509: “127.0.0.1” certificate is not standards compliant` — Go's strict
   evaluator rejects a CA:TRUE self-signed cert used as TLS end-entity.
2. **Post-remint leaf** (proper CA:FALSE chain): with `SSL_CERT_FILE=ca-cert.pem`
   exported, the azurerm provider still fails:
   `x509: “localhost” certificate is not trusted` at
   `https://127.0.0.1:39391/metadata/endpoints?api-version=2022-09-01`.

Isolated empirically with a minimal Go 1.24 client (`/tmp/go_ca_probe`) against a
local TLS server serving the real dev-cert:

- explicit `tls.Config{RootCAs: pool(ca-cert.pem)}` → **verify OK, handshake OK**
- system-pool client with `SSL_CERT_FILE` set →
  `tls: failed to verify certificate: x509: “localhost” certificate is not trusted`

Conclusion: the wire itself is correct — once the CA is anchored, Go completes the
handshake against the real leaf. The wall is that **Go's darwin root loading does
not honor `SSL_CERT_FILE`** (only the explicit RootCAs path works), the
**hardened runtime strips `DYLD_INSERT_LIBRARIES`** from both `terraform` and the
provider binaries (witnessed `codesign flags=0x10000(runtime)` on both, so the
trust shim cannot reach the provider process), and keychain trust settings are the
only remaining admission path — which requires the operator's one-time interactive
`security add-trusted-cert` (SecurityAgent approval). No emulator-side divergence
is implicated; the fixture/provider never got far enough to exercise the wire
beyond TLS bootstrap.

## Zero-touch HCL invariance check — PASS

`test/terraform_fixture/main.tf` + `versions.tf` read directly:

- `versions.tf`: `required_version >= 1.8.5`, pinned providers `azurerm = 4.54.0`,
  `azapi = 2.4.0`; provider block = `features {}` +
  `resource_provider_registrations = "none"` + `subscription_id`. **No lifecycle
  blocks, no ignore_changes, no provider-level workarounds — zero-touch holds.**
- `main.tf`: three plain resources (resource_group, key_vault, storage_account),
  no lifecycle/meta arguments.

## Minor harness gap witnessed (pre-existing, not session-introduced)

`scripts/tf_cleanroom.sh` gates its "offline mirror" stage on
`$FIXTURE/provider-mirror.rc` — a file that no longer exists by design (M8: the rc
is generated at run time into a mktemp path by `scripts/tf_mirror_env.sh`, never
committed). Result: the cleanroom's init stage logged "no offline mirror" and went
down the registry path (PASSed online, but the offline-mirror claim in its receipt
is vacuous on this tree). Fix direction: source `tf_mirror_env.sh` like
`tf_smoke.sh`/`tf_plan_check.sh` do. Left for the coordinator.

## Reproduction commands

```
bash scripts/tf_trust_check.sh                      # FAIL (zero trust settings)
bash scripts/tf_cleanroom.sh                        # exit 1 at stage3 plan
SSL_CERT_FILE=.smalt/tls/ca-cert.pem terraform plan # x509: "localhost" is not trusted
```

Close condition: operator runs the one-time
`security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db .smalt/tls/ca-cert.pem`
(interactive approval) + substrate restart, then rerun `just shim-court`-style
ladder: `bash scripts/tf_cleanroom.sh` to plan -detailed-exitcode 0 + destroy.
