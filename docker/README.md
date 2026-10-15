# docker — smalt substrate packaging

Multi-stage container packaging for the smalt BEAM-native substrate
(ARM-style control plane on 9443, data-plane egress on 8443, AMQP on
5672/5673).

## Files

- `docker/Dockerfile` — multi-stage build: `elixir:1.18-slim` builder,
  `debian:bookworm-slim` runtime with only the BEAM release.
- `docker/compose.smalt.yml` — loopback-only hardened local deployment.

## Build

From the repo root. The two sibling path dependencies declared in
`mix.exs` (`../ash_graphlaw`, `../ggen_igniter`) are injected as extra
build contexts so the build stays self-contained:

```sh
docker build -f docker/Dockerfile -t smalt:local . \
  --build-context ash_graphlaw=../ash_graphlaw \
  --build-context ggen_igniter=../ggen_igniter
```

Or let compose do it:

```sh
docker compose -f docker/compose.smalt.yml up --build -d
```

## Run

```sh
docker compose -f docker/compose.smalt.yml up -d
```

## Port map

| Container | Host (loopback only) | Surface |
|---|---|---|
| 9443 | 127.0.0.1:9443 | ARM control plane / REST / STS / discovery |
| 8443 | 127.0.0.1:8443 | Athena data-plane egress router |
| 5672 | 127.0.0.1:5672 | AMQP 1.0 broker (Service Bus mode) |
| 5673 | 127.0.0.1:5673 | Event Hubs-compatible listener |

All mappings are bound to `127.0.0.1`; nothing is reachable from the
network.

## Health

The image carries a TCP HEALTHCHECK on 9443
(`exec 3<>/dev/tcp/127.0.0.1/9443`). Check with:

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

As of 2026-10-14 the census fails 0/8 against both the container and the
host substrate (SAS signature-scheme mismatch in
`SasVerifier` + `QueueStore.dequeue_matching/2` typing violation); see
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
