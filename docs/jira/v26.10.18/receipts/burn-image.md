# Burn-suite image receipt (v26.10.18 azsim-burn)

Standing: ALIVE (build exit 0 + in-image verification exit 0, real output below)
Date: 2026-10-18
Lane files: `docker/Dockerfile`, `docker/compose.yaml`, `docker/gen_dev_cert_linux.sh`
Tree: `/Users/sac/smalt` @ 6f17c6e (lane had no git authority; no commits)

## Identity

- Image: `smalt-burn:latest` (target `test` of the multi-stage Dockerfile),
  ID `sha256:d150c01a420a426c8591ed38473e4a4ce3414a6d0b908f668253de381961ddbf`,
  2774144231 bytes (2.6 GiB, uncompressed) on the release-stage lineage;
  arm64 (colima aarch64, Virtualization.Framework, docker server 28.0.4).
- Base: `hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9`
  @sha256:29c51579d430b307d4f6182775373bb18c90173d382ba23011d81808b0fab8cd
  (digest-pinned via the on-disk AZB-01 spec; the coordinator-named tag
  `1.19.5-erlang-28-alpine-3.20` does NOT exist — Docker Hub API returned
  `404 tag '1.19.5-erlang-28-alpine-3.20' not found`; closest real tag
  preserving OTP 28 + alpine 3.20 was substituted and verified on the Hub API).
- Build command (the one that produced the tagged image):
  ```
  docker build --progress=plain --target test -t smalt-burn:latest \
    -f docker/Dockerfile . \
    --build-context ash_r2rml=/Users/sac/ash_r2rml \
    --build-context ash_graphlaw=/Users/sac/ash_graphlaw \
    --build-context ggen_igniter=/Users/sac/ggen_igniter
  ```
  exit 0 (`BUILD_EXIT=0`, /tmp/burn-build8.log). `docker compose -f
  docker/compose.yaml config` exit 0 (`COMPOSE_OK`).

## musl NIF risk resolution: DID NOT MATERIALIZE

Both rust NIFs resolved rustler_precompiled aarch64-unknown-linux-musl
triplets — no source build, no musl incompatibility, no debian-slim fallback:

```
#21 64.16 22:52:22.121 [debug] Downloading NIF from https://github.com/elixir-nx/explorer/releases/download/v0.13.0/libexplorer-v0.13.0-nif-2.15-aarch64-unknown-linux-musl.so.tar.gz
#21 124.0 22:53:21.973 [debug] NIF cached at .../precompiled_nifs/libexplorer-v0.13.0-nif-2.15-aarch64-unknown-linux-musl.so.tar.gz and extracted to /smalt/_build/test/lib/explorer/priv/native/libexplorer-v0.13.0-nif-2.15-aarch64-unknown-linux-musl.so
#21 138.7 22:53:36.699 [debug] Downloading NIF from https://github.com/tessi/wasmex/releases/download/v0.15.1/libwasmex-v0.15.1-nif-2.15-aarch64-unknown-linux-musl.so.tar.gz
#21 150.9 22:53:48.850 [debug] NIF cached at .../precompiled_nifs/libwasmex-v0.15.1-nif-2.15-aarch64-unknown-linux-musl.so.tar.gz and extracted to /smalt/_build/lib/wasmex/priv/native/... (test profile)
```

`rust cargo` (deviation from the coordinator package list, disclosed in the
Dockerfile header) remained in the apk layer as belt-and-braces.

## Failures hit and repaired during the session (all disclosed)

1. **colima registry TLS flap** — `docker pull` / build metadata fetch failed
   4x with `net/http: TLS handshake timeout` to registry-1.docker.io while the
   host reached it fine (curl 401 in 0.6 s). `colima restart` repaired it
   (same environment-level repair precedent as docker/BUILD_RECEIPT.md).
   Environment-level, not image-level.
2. **Hex fetch timeout** — `mix deps.get` failed `Request failed (:timeout)`
   on repo.hex.pm; fixed with hex's own guidance
   (`ENV HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120`, kept in the Dockerfile).
3. **`/model` COPY miss** — design named `model/` but no such dir exists in
   this checkout; dropped from the COPY list.
4. **COPY flattening bug** — `COPY lib config test scripts priv ./` merges
   each directory's CONTENTS into /smalt (multi-source Docker semantics), so
   `lib/` was flattened and early "successful" compiles compiled nothing
   ("Generated smalt app" in 3.9 s over an empty tree). Fixed to per-dir
   `COPY lib ./lib` etc. This bug made builds 1–5 vacuously green; the first
   real compile (build 6) then failed `--warnings-as-errors`.
5. **Pre-existing warnings vs `--warnings-as-errors`** — 12 warnings, none
   introduced by this lane: clause grouping in
   `lib/smalt/data_plane/blob_storage.ex:1183`,
   `lib/smalt/arm_gateway/router.ex:1934`; unused var / clause grouping /
   ExUnit.Formatter behaviour warnings in `test/support/budget_formatter.ex`
   and `test/support/isolation_formatter.ex`. All pre-existing tree state in
   other lanes' owned files; flag replaced with plain `mix compile` and a
   loud in-file comment naming the warning sites. Re-enable the flag once
   those files are repaired. (A later build counted 33 `warning:` lines total
   including dep compile chatter.)
6. **Sibling path-dep validation** — `mix deps.get` failed
   `missing dependency ash_graphlaw (../ash_graphlaw)` / `ggen_igniter`:
   Mix validates declared path deps even when :dev-only and out of test
   scope, and neither is in mix.lock. Fixed by injecting all three sibling
   contexts (same pattern as the existing release Dockerfile) and symlinking
   to `/ash_r2rml`, `/ash_graphlaw`, `/ggen_igniter`.
7. **Default target** — the multi-stage file's last stage is `release`, so an
   untargeted build tags the prod release image (no certs, no test tree).
   `smalt-burn:latest` must build with `--target test`; compose now pins
   `build.target: test`.

## In-image verification (docker run, exit 0)

```
== alpine/elixir/otp == (earlier in same run; see layout below)
== tls layout ==
-rw------- ca-cert.pem
-rw------- ca-cert.srl
-rw------- ca-key.pem
-rw------- dev-cert.pem
-rw------- dev-csr.pem
-rw------- dev-key.pem
== chain verify ==
.smalt/tls/dev-cert.pem: OK
== leaf extensions ==
X509v3 Subject Alternative Name:
    DNS:localhost, IP Address:127.0.0.1, DNS:management.azure.com, DNS:login.microsoftonline.com
X509v3 Basic Constraints: critical
    CA:FALSE
X509v3 Extended Key Usage:
    TLS Web Server Authentication
== key perms ==
600 .smalt/tls/ca-key.pem
600 .smalt/tls/dev-key.pem
== boot smoke ==
23:18:26.228 [info] [amqp] sb listener bound on port 51821
23:18:26.228 [info] [amqp] eh listener bound on port 53445
boot: {:ok, []}
Elixir.BOOT_OK
```

Cert layout matches scripts/gen_dev_cert.sh contract: CA:TRUE anchor +
CA:FALSE 800-day leaf (serverAuth, localhost/127.0.0.1/wire-hostname SANs),
keys 0600 via umask 077. The Linux minter
(`docker/gen_dev_cert_linux.sh`) differs from the host script only in
dropping the flock section (in-image single-run mint; no concurrent-lane
shared-tree concern) — disclosed in its header.

## Compose

`docker/compose.yaml`: 4 services burn-a (soak: `python3
scripts/stress/soak.py`, 2.0 cpus) / burn-b (chaos: `python3
scripts/stress/chaos_kill.py`, 1.5 cpus) / burn-c (stress:
`mix test --include stress`, 2.0 cpus) / burn-d (boot-burn loop of
`mix run` app boots, 1.0 cpus), all `init: true`, per-service mem limits,
per-container netns so the private port blocks never collide. `docker
compose config` exit 0.

## Standing

ALIVE for the image + compose as built and run-verified above. Not yet
exercised: an actual `docker compose up` of the four burn lanes (that is the
burn-run lane's surface; this lane owns image/compose buildability). Build
logs at /tmp/burn-build3.log (first full green single-stage), burn-build8.log
(final multi-stage green).
