# DEV_ENV

# Dev Environment Bootstrap

`scripts/dev_env.sh` materializes the dev environment for the smalt canonical
checkout. It is idempotent and deterministic: two consecutive runs on the same
host produce byte-identical output.

```sh
eval "$(scripts/dev_env.sh)"   # export into the current shell
scripts/dev_env.sh --check     # validate + scripts/doctor.py quick pass
```

## Variables

| Variable | Derivation | Consumers |
|---|---|---|
| `SMALT_SB_SHARED_KEY` | base64(sha256(hostname + `"smalt-dev-sb"`)) — 44 bytes, stable per host | Substrate pins it into `:smalt, :sb_shared_key` via `lib/smalt/messaging/amqp/connection.ex` (`ensure_cbs_router/0`), and `SasVerifier` (`lib/smalt/messaging/amqp/sas_verifier.ex`) HMAC-verifies AMQP SAS tokens against it. External SDK probes (post-reset: the `verification/ts` + `verification/py` suites; pre-reset `test/sdk-smoke/*` equivalents were deleted at 64f6099) read it to sign SAS tokens. Deterministic derivation means SDK probes and the substrate agree without a shared-secret ceremony. |
| `SMALT_SDK_ROOT` | In-repo default `verification/ts/node_modules` when present (v26.10.19, per `scripts/dev_env.sh`); a user-provided `SMALT_SDK_ROOT` wins; left UNSET with a LOUD WARN when neither exists | TS SDK probes (post-reset home `verification/ts/`; the pre-reset `test/sdk-smoke/*` + `test/data_plane/sdk_probe.mjs` consumers were deleted at 64f6099). |
| `SMALT_REPO` | `$PWD` when it contains `mix.exs`, else error | Repo-root anchor for external probe harnesses spawning the substrate (`cwd: REPO`). |
| `SMALT_TLS_CERTFILE` / `SMALT_TLS_KEYFILE` | `.smalt/tls/dev-cert.pem` / `dev-key.pem` when minted (`scripts/gen_dev_cert.sh`) | TLS twin listener, `lib/smalt/application.ex` (`cert = System.get_env("SMALT_TLS_CERTFILE")`); also set by `tf_smoke.sh`. |
| `SSL_CERT_FILE` | `.smalt/tls/ca-cert.pem` when minted | Go SDK probes — Apple Security.framework chain verification needs the CA anchor (`scripts/gen_dev_cert.sh` header explains the CA:TRUE/CA:FALSE chain rationale). |

## Failure modes

- Missing SDK root: LOUD WARN on stderr (not a hard error) naming
  `verification/ts/node_modules` and the npm install / export fix;
  `SMALT_SDK_ROOT` is left unset.
- No `mix.exs` in cwd: error says run from repo root or set `SMALT_REPO`.
- TLS material absent: exported block simply omits `SMALT_TLS_*` (mint with
  `scripts/gen_dev_cert.sh`).

## Verification receipt (2026-10-14)

```text
$ bash scripts/dev_env.sh --check; echo "exit=$?"
[dev_env] --check: validating
  SMALT_SB_SHARED_KEY = 3UKYV3ba... (44 bytes)
  SMALT_SDK_ROOT      = <legacy-sdk-root>/playground/node_modules
  SMALT_REPO          = ~/smalt
  SMALT_TLS_CERTFILE  = ~/smalt/.smalt/tls/dev-cert.pem
  SMALT_TLS_KEYFILE   = ~/smalt/.smalt/tls/dev-key.pem
  SSL_CERT_FILE       = ~/smalt/.smalt/tls/ca-cert.pem
[dev_env] env validation passed; running scripts/doctor.py
=== SMALT DOCTOR DIAGNOSTIC COURT ===
[PASS] binaries: ok
[PASS] port-9443: port 9443 free
[PASS] port-8443: port 8443 free
[PASS] port-5672: port 5672 free
[PASS] substrate-liveness: NOT-RUNNING (URLError)
[PASS] amqp-handshake: PASS-FREE (broker not listening — pre-boot)
[PASS] Smalt doctor diagnostic court passed.
exit=0
```

Two consecutive plain runs produce byte-identical eval output (verified).

## See Also

`scripts/dev_env.sh`, `scripts/gen_dev_cert.sh`, `scripts/doctor.py`
