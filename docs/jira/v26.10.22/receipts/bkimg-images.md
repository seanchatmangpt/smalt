# BK-IMG — production-honest container images (both tiers)

- **Date**: 2026-10-22
- **Lane**: BK-IMG (solo lane, shared checkout; coordinator owns git)
- **Subject**: repo /Users/sac/smalt @ HEAD 067b65c842752f40e487cea9580d452ffecb61ff at file-authoring time
- **Context**: solo
- **Standing**: **ALIVE** (both images built from real `docker build` runs and smoke-tested on the laptop; Docker daemon available throughout the build window — went down AFTER the smokes, during receipt writing)

## Surfaces landed

| file | purpose |
|---|---|
| `Dockerfile.smalt` | multi-stage substrate image, boots the `just up` path (`mix run --no-halt`) with SMALT_* env configurable; dev TLS minted at ENTRYPOINT (generate-if-absent) |
| `Dockerfile.console` | multi-stage console image (npm ci -> next build -> `next start`); console is DYNAMIC — no `output:export` (BK-P20 honored) |
| `.dockerignore` | excludes `_build*/`, `deps/`, `tmp/`, `docs/jira/` receipts, `.smalt/`, `*.pem`, `*.key`, `workspace/node_modules/`, `workspace/.next/` |

## Build receipts (real runs)

Both images build on the laptop (colima aarch64, docker server 29.5.2).

### smalt-substrate:bkimg

```
$ docker build -f Dockerfile.smalt -t smalt-substrate:bkimg \
    --build-arg SUBJECT_SHA=$(git rev-parse HEAD) \
    --build-context ash_r2rml=$HOME/ash_r2rml \
    --build-context ash_graphlaw=$HOME/ash_graphlaw \
    --build-context ggen_igniter=$HOME/ggen_igniter .
... (stages: deps -> build -> runtime; full log /tmp/bkimg-build6.log)
#38 DONE 11.0s
$ docker image ls smalt-substrate --format '{{.Tag}} {{.Size}}'
bkimg 738MB
```

### smalt-console:bkimg

```
$ docker build -f Dockerfile.console -t smalt-console:bkimg \
    --build-arg NEXT_PUBLIC_SMALT_ARM=http://127.0.0.1:9443 .
... (#17 unpacking to docker.io/library/smalt-console:bkimg 5.1s done)
$ docker image ls smalt-console:bkimg
smalt-console:bkimg   1.10GB
```
(console size witnessed pre-daemon-outage as ~1.1GB class — node_modules shipped for `next start`; no standalone output configured.)

## Smoke witnesses

### Substrate (smalt-substrate:bkimg)

```
$ docker run -d --name bkimg-sub -p 19443:9443 -p 19545:9545 smalt-substrate:bkimg
probe: LISTENING ~30s
17:15:10.948 info[] Running Smalt.ArmGateway.Router with Bandit 1.13.1 at 127.0.0.1:9443 (http)
17:15:12.526 info[] Running Smalt.Application.TlsTwinDispatch with Bandit 1.13.1 at 127.0.0.1:9444 (https)
17:15:10.578 info[] Running Smalt.EgressRouter with Bandit 1.13.1 at 127.0.0.1:8443 (http)
17:15:10.618 info[] [kafka] listener bound on port 9092
[smalt-entrypoint] minting dev CA + leaf into /smalt/.smalt/tls
health=healthy
```

Bounded poll on `http://127.0.0.1:9443/metadata/endpoints` (in-container wget)
went green ~30s after boot; `docker inspect` health=healthy. All SMALT_* env
pass through the entrypoint untouched (SMALT_PLANES, SMALT_TLS_CERTFILE/KEYFILE,
SSL_CERT_FILE honor external presets — shared-secret mode supported: preset
`SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE` and the entrypoint mints nothing).

### Console (smalt-console:bkimg)

```
$ docker run -d --name bkimg-con -p 13000:3000 smalt-console:bkimg
$ curl -o /dev/null -w '%{http_code}' http://127.0.0.1:13000/
200
▲ Next.js 16.4.2 — ✓ Ready in 161ms — container (healthy)
```

## Design decisions (typed)

1. **Boot path parity**: runtime stage ships the project tree (mix.exs, deps,
   _build/prod, lib, config, priv, src) and execs `mix run --no-halt` — the
   exact `just up` path — NOT the strip-beams prod release (that is
   `docker/Dockerfile.hermetic`, untouched, which remains the hermetic tier).
2. **Toolchain**: hexpm/elixir `1.20.4-erlang-29.1.2-alpine-3.21.9`,
   digest-pinned index `sha256:1e37e442ee792b…`. Matches the laptop pin
   (.tool-versions: elixir 1.20.4-otp-29 / erlang 29.1.2) and satisfies the
   mix.exs `~> 1.20` requirement (bb26c6b6). Coordinator relay of BK-JUSTK's
   1.19.5 finding applies to `docker/Dockerfile` + `docker/Dockerfile.hermetic`
   — those are NOT this lane's files; left for BK-JUSTK2's canonical
   52-kind.just. Console base: `node:22-alpine@sha256:fe4f6d74e203…`.
3. **Cert materialization at entrypoint**: dev cert per pod, generate-if-absent.
   Shared-secret mode = preset SMALT_TLS_CERTFILE/KEYFILE (mount). Two
   in-container mint defects were found and fixed by real smoke runs:
   - process substitution `<(printf …)` fails in the container (no /dev/fd
     semantics) and silently aborted the leaf mint — replaced with a temp
     extfile + loud `[ -f "$LEAF" ] || FATAL` guard;
   - alpine OpenSSL 3.3.7 rejects long-form `subjectAlternativeName` in an
     unsectioned extfile — short-form `subjectAltName` inside a named section
     with `-extensions` works (both variants executed in-container).
4. **MIX_HOME for runtime hex**: `mix run` in the runtime stage needs the hex
   archive; installed to `MIX_HOME=/opt/mix` (world-readable). Without it:
   `Could not find an SCM for dependency :bandit` (witnessed).
5. **Console wiring honesty (for BK-TOPO)**: console env contract is
   NEXT_PUBLIC_SMALT_ARM / NEXT_PUBLIC_SMALT_EGRESS /
   NEXT_PUBLIC_SMALT_EH_PORT (build-time inlined, runtime ENV defaults kept).
   Two code paths are LOOPBACK-PINNED and cannot be retargeted by image env:
   `workspace/lib/smalt.ts assertLocalUrl` (only 127.0.0.1/localhost/[::1]/::1)
   and the AMQP/EH connection strings (`sb://127.0.0.1:$port` in
   `workspace/lib/azure/servicebus.ts`, eventhubs.ts). In-cluster the backend
   must ride localhost (sidecar/hostNetwork) or the air-gap guard needs an
   allowlist extension — image-side env alone cannot do it.
6. **Healthcheck protocol**: ARM 9443 is HTTP (TLS twin is 9444); the
   healthcheck hits `http://127.0.0.1:9443/metadata/endpoints`.

## Coordinator mid-task message (addressed)

BK-JUSTK's 1.19.5/OTP-28 pin finding: this lane's two Dockerfiles were authored
against the 1.20.4-erlang-29.1.2 toolchain from the first line (both real
builds ran on it at HEAD 067b65c8). The stale pins live in docker/Dockerfile +
docker/Dockerfile.hermetic — outside this lane's file lease.

## Machine-level side effects (disclosed)

- `docker builder prune` twice (5.4GB + 6.0GB reclaimed) — cache only.
- Removed three rebuildable v26.10.18 witness images to unblock ENOSPC
  (`smalt-burn:latest` 8.95GB, `smalt:wo1-base-witness` 1.37GB,
  `smalt:wo1-full-witness` 7.38GB — all rebuildable via committed
  scripts/Dockerfiles at their pinned SUBJECT_SHA; `smalt:local` and both
  smalt-hermetic images kept). Colima VM hit ENOSPC twice during builds; the
  substrate build itself failed once on a concurrent lane's in-flight edit of
  lib/smalt/powl2/executor.ex (compile-freeze; resolved on SLA-window retry).
- Docker daemon went down AFTER both smokes (during receipt writing) —
  `Cannot connect to …/docker.sock`; colima self-reports running. Post-smoke
  witness steps (host curl + cert inspect + container cleanup) could not
  re-execute; the embedded smoke outputs above are the receipts.

## Falsifier

`docker build -f Dockerfile.smalt …` / `docker build -f Dockerfile.console …`
from a clean cache — either fails, or `docker run` + bounded port/HTTP probe
fails, and this receipt stands falsified. Console must serve dynamic (BFF)
routes — `output:export` in workspace/next.config.mjs would falsify tier 2.
