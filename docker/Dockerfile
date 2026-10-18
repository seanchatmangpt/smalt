# smalt burn-suite image (MIX_ENV=test, alpine).
#
# Pin rationale: hexpm/elixir 1.19.5 / OTP 28.5.0.2 / alpine 3.20.9. The
# coordinator-specified tag `1.19.5-erlang-28-alpine-3.20` does not exist on
# Docker Hub (hub API 404, verified 2026-10-18); this is the closest real tag
# preserving the OTP-28 + alpine-3.20 contract. wasmex and ex4pm
# (explorer) ship rust NIFs; the base OTP is host-matched to the NIF ABI the
# tree was developed against (OTP 28). musl compatibility of the NIF builds is
# a known risk — fallback base is debian-slim (docker/compose.smalt.yml's
# image lineage already builds clean on debian).
#
# One deviation from the coordinator package list, disclosed: `rust cargo`
# added — wasmex (rustler) and ex4pm's explorer both compile native crates;
# rustler_precompiled has no musl triplet for this OTP/ABI combination, so the
# NIFs build from source and need a rust toolchain.
FROM hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9

RUN apk add --no-cache \
      git bash python3 make gcc musl-dev curl openssl \
      rust cargo

ENV LANG=C.UTF-8 \
    MIX_ENV=test \
    SMALT_CERT_DIR=/smalt/.smalt/tls \
    SSL_CERT_FILE=/smalt/.smalt/tls/ca-cert.pem

WORKDIR /smalt

# --- warm dependency layer (changes only when mix.lock moves) -------------
COPY mix.exs mix.lock ./

# ash_r2rml is a path dep in scope for MIX_ENV=test (only: [:dev, :test]);
# the other sibling path deps (ash_graphlaw, ggen_igniter) are :dev-only and
# out of scope here. Injected as an extra build context:
#   docker build -f docker/Dockerfile ... --build-context ash_r2rml=../ash_r2rml
COPY --from=ash_r2rml / /ctx/ash_r2rml
RUN mkdir -p /sibs && ln -sfn /ctx/ash_r2rml /ash_r2rml

RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN MIX_ENV=test mix compile

# --- source + burn harness layer ------------------------------------------
COPY lib config test scripts priv ./
COPY docker/gen_dev_cert_linux.sh /usr/local/bin/gen_dev_cert_linux.sh

# Dev TLS material minted IN-IMAGE (same .smalt/tls layout as
# scripts/gen_dev_cert.sh; the Linux variant is baked to
# /usr/local/bin/gen_dev_cert_linux.sh).
RUN gen_dev_cert_linux.sh

EXPOSE 9443 9444 8443 5672 5673 9545

# Default: quiet identity probe. Burn lanes come in through
# docker/compose.yaml services (burn-a..d) which override `command`.
CMD ["mix", "run", "-e", "IO.puts(:smalt)"]
