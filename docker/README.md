# docker — smalt substrate packaging

Multi-stage container packaging for the smalt BEAM-native substrate
(ARM-style control plane on 9443, data-plane egress on 8443, AMQP on
5672/5673).

## Files

- `docker/Dockerfile` — multi-stage build: `elixir:1.18-slim` builder,
  `debian:bookworm-slim` runtime with only the BEAM release.
- `docker/compose.smalt.yml` — loopback-only hardened local deployment.

## Build

From the repo root. The three sibling path dependencies declared in
`mix.exs` (`../ash_graphlaw`, `../ggen_igniter`, `../ash_r2rml`) are injected
as extra build contexts so the build stays self-contained (`ex4pm` resolves
from hex.pm since 26.10.14 — no build context; `ash_graphlaw`/`ggen_igniter`
are :dev-only and `ash_r2rml` is dev/test-only, but Mix still validates all
three declared paths at `mix deps.get`, so all three must be present):

```sh
docker build -f docker/Dockerfile -t smalt:local . \
  --build-context ash_graphlaw=$PWD/../ash_graphlaw \
  --build-context ggen_igniter=$PWD/../ggen_igniter \
  --build-context ash_r2rml=$PWD/../ash_r2rml
```

Or let compose do it:

```sh
docker compose -f docker/compose.smalt.yml up --build -d
```

## Run

```sh
docker compose -f docker/compose.smalt.yml up -d
```

Zero-config: no env vars, no host paths, no manual cert or key steps.
TLS is `:auto` (the app self-mints a per-boot self-signed dev cert into
the container's tmpfs `/tmp`); the SAS key is pinned via the compose
`environment` block (see below).

**Dev-only defaults**: `SMALT_SB_SHARED_KEY` and `SMALT_BIND_IP=0.0.0.0`
are baked into `docker/compose.smalt.yml` as documented dev values.
Production deployments must supply real secrets via their own env/secret
store and keep loopback-only exposure — do not ship this compose file as-is.

## Port map

| Container | Host (loopback only) | Surface |
|---|---|---|
| 9443 | 127.0.0.1:9443 | ARM control plane / REST / STS / discovery |
| 9444 | 127.0.0.1:9444 | ARM TLS twin (SDK legs) |
| 8443 | 127.0.0.1:8443 | data-plane egress router |
| 5672 | 127.0.0.1:5672 | AMQP 1.0 broker (Service Bus mode) |
| 5673 | 127.0.0.1:5673 | Event Hubs-compatible listener |
| 9545 | 127.0.0.1:9545 | MCP tool surface |

All mappings are bound to `127.0.0.1`; nothing is reachable from the
network.

## Health

The **compose deployment** defines a TCP healthcheck on 9443
(`exec 3<>/dev/tcp/127.0.0.1/9443` in `compose.smalt.yml`'s `healthcheck:` block —
the image itself carries no HEALTHCHECK instruction, so bare `docker run`
containers report no health state). Check with:

```sh
docker inspect --format '{{.State.Health.Status}}' smalt
```

Smoke test from the host once the container is healthy:

```sh
curl -s http://127.0.0.1:9443/common/discovery/instance
curl -s http://127.0.0.1:9443/.well-known/openid-configuration
```

## SDK census against the container

The SDK census (`test/sdk-smoke/census.test.cjs`) needs the broker's SAS
key. The container mints a random dev key at boot, so to point the census
at the container, run it with a pinned key via a release `eval` override
(same ports/hardening as compose):

```sh
docker run -d --name smalt --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -p 127.0.0.1:9443:9443 -p 127.0.0.1:8443:8443 \
  -p 127.0.0.1:5672:5672 -p 127.0.0.1:5673:5673 \
  smalt:local eval 'Application.put_env(:smalt, :sb_shared_key, "<base64-key>");
    {:ok,_}=Application.ensure_all_started(:smalt); Process.sleep(:infinity)'
SMALT_SDK_ROOT=<node_modules with @azure packages> \
SMALT_SB_SHARED_KEY=<base64-key> \
node --test test/sdk-smoke/census.test.cjs
```

Census results are a running register, not a fixed snapshot — do not cite a
dated pass count here. Live truth: `just sdk-census` (exit 0 pass / 1 fail /
2 substrate down / 3 SKIP) and the generated
`docs/jira/v<version>/SDK_MATRIX.md`; the container build's own record lives in
`docker/BUILD_RECEIPT.md`.

## Hardening

- Runs as UID/GID 65532 (distroless `nonroot` convention), no shell login.
- `read_only: true` root filesystem; only writable path is tmpfs `/tmp`
  (`RELEASE_TMP=/tmp`, `HOME=/tmp` — no writes outside `/tmp`).
- `cap_drop: ALL`, `no-new-privileges`, 2 CPU / 2 GB limits.

## Tests

Tests run on the host, not in the container. The image ships the prod
release only; no test sources, deps, or mix toolchain are present in the
runtime image. Run the suite from a host checkout (`mix test` / the
repo's Justfile targets), not against the container.
