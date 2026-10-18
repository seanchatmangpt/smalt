# smalt burn-suite image (AZB-01, v26.10.18 azsim-burn).
#
# AZB-01 spec: base pinned by digest; multi-stage (test target + release
# target from one Dockerfile); layer order mix.exs+mix.lock -> deps ->
# lib/ config/ priv/ -> compile --warnings-as-errors; label
# org.smalt.subject=<git sha>.
#
# Pin: hexpm/elixir 1.19.5 / OTP 28.5.0.2 / alpine 3.20.9, multi-arch index
# digest sha256:29c51579d430b307d4f6182775373bb18c90173d382ba23011d81808b0fab8cd
# (resolved via `docker buildx imagetools inspect` 2026-10-18; the
# coordinator-specified tag `1.19.5-erlang-28-alpine-3.20` does not exist on
# Docker Hub, hub API 404). wasmex and ex4pm (explorer) ship rust NIFs; the
# base OTP is host-matched to the NIF ABI the tree was developed against
# (OTP 28). musl compatibility of the NIF builds is a known risk — fallback
# base is debian-slim.
#
# One deviation from the coordinator package list, disclosed: `rust cargo`
# added — wasmex (rustler) and ex4pm's explorer both compile native crates;
# rustler_precompiled has no musl triplet for this OTP/ABI combination, so
# the NIFs build from source and need a rust toolchain.
FROM hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9@sha256:29c51579d430b307d4f6182775373bb18c90173d382ba23011d81808b0fab8cd AS base

# Subject identity: default is the checkpoint-6 head this image lineage was
# cut from; overridable at build time without breaking the pin
#   docker build --build-arg SUBJECT_SHA=$(git rev-parse HEAD) ...
ARG SUBJECT_SHA=29bb0371426a270c9c9ac2dc483b7e2a9d226938
LABEL org.smalt.subject=${SUBJECT_SHA}
# AZB-03: runtime export so burn emitters mint schema-valid run receipts
# (identity.subject_sha requires 40-hex; git is absent in the runtime stage).
ENV SMALT_BURN_SUBJECT_SHA=${SUBJECT_SHA}

RUN apk add --no-cache \
      git bash python3 make gcc musl-dev curl openssl \
      rust cargo

ENV LANG=C.UTF-8 \
    MIX_ENV=test \
    SMALT_CERT_DIR=/smalt/.smalt/tls \
    SSL_CERT_FILE=/smalt/.smalt/tls/ca-cert.pem

WORKDIR /smalt

# --- warm dependency layer (changes only when mix.lock moves) -------------
FROM base AS deps
COPY mix.exs mix.lock ./

# ash_r2rml is a path dep in scope for MIX_ENV=test (only: [:dev, :test]);
# the other sibling path deps (ash_graphlaw, ggen_igniter) are :dev-only and
# out of scope here. Injected as an extra build context:
#   docker build -f docker/Dockerfile ... --build-context ash_r2rml=/Users/sac/ash_r2rml
COPY --from=ash_r2rml / /ctx/ash_r2rml
RUN mkdir -p /sibs && ln -sfn /ctx/ash_r2rml /ash_r2rml

RUN mix local.hex --force && mix local.rebar --force
# HEX_HTTP_CONCURRENCY=1 + long timeout: the colima VM's NAT has shown TLS
# flaps to registry-1.docker.io and repo.hex.pm in this session; hex's own
# guidance for consistent fetch failures.
ENV HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120
RUN mix deps.get
RUN MIX_ENV=test mix deps.compile
RUN MIX_ENV=prod mix deps.compile

# --- test target ------------------------------------------------------------
FROM deps AS test
COPY lib config test scripts priv ./
COPY docker/gen_dev_cert_linux.sh /usr/local/bin/gen_dev_cert_linux.sh

# Dev TLS material minted IN-IMAGE (same .smalt/tls layout as
# scripts/gen_dev_cert.sh; the Linux variant is baked to
# /usr/local/bin/gen_dev_cert_linux.sh).
RUN gen_dev_cert_linux.sh

RUN mix compile --warnings-as-errors
EXPOSE 9443 9444 8443 5672 5673 9545

# Default: quiet identity probe. Burn lanes come in through
# docker/compose.yaml services (burn-a..d) which override `command`.
CMD ["mix", "run", "-e", "IO.puts(:smalt)"]

# --- release target (prod) --------------------------------------------------
FROM deps AS release
ENV MIX_ENV=prod
COPY lib config priv ./
RUN mix compile --warnings-as-errors
RUN mix release smalt --path /app/_release
EXPOSE 9443 9444 8443 5672 5673 9545
CMD ["/app/_release/bin/smalt", "start"]
