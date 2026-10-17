# Multi-stage build for the smalt substrate release.
#
# The three sibling path dependencies are injected as extra build contexts:
#
#   docker build -f docker/Dockerfile -t smalt:local . \
#     --build-context ash_graphlaw=../ash_graphlaw \
#     --build-context ggen_igniter=../ggen_igniter \
#     --build-context ex4pm=../ex4pm
#
# See docker/README.md.

FROM elixir:1.18-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
ENV LANG=C.UTF-8

WORKDIR /app

COPY mix.exs mix.lock ./

# Sibling path deps must exist at ../ash_graphlaw and ../ggen_igniter
# relative to /app (i.e. /ash_graphlaw, /ggen_igniter). Copy the injected
# build contexts and symlink them into those paths.
# ash_r2rml / ash_ex4pm are optional-only deps (dev/test) — not copied here.
COPY --from=ash_graphlaw / /ctx/ash_graphlaw
COPY --from=ggen_igniter / /ctx/ggen_igniter
COPY --from=ex4pm / /ctx/ex4pm
RUN mkdir /sibs \
 && ln -sfn /ctx/ash_graphlaw /ash_graphlaw \
 && ln -sfn /ctx/ggen_igniter /ggen_igniter \
 && ln -sfn /ctx/ex4pm /ex4pm

RUN mix local.hex --force \
 && mix local.rebar --force

RUN mix deps.get \
 && mix deps.compile

COPY lib ./lib
COPY priv ./priv
COPY config ./config

RUN mix compile

RUN mix release smalt --path /app/_release

# ---------------------------------------------------------------------------
# Runtime: Debian slim, release only. No Elixir/Mix toolchain.
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl libssl3 ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

# Non-root, distroless-style UID/GID.
RUN groupadd -g 65532 nonroot \
 && useradd -u 65532 -g 65532 -s /usr/sbin/nologin nonroot

ENV HOME=/tmp
ENV RELEASE_TMP=/tmp
ENV RELEASE_DISTRIBUTION=none
ENV RELEASE_NODE=smalt

COPY --from=build --chown=65532:65532 /app/_release /opt/smalt

USER 65532:65532
WORKDIR /tmp

EXPOSE 9443 8443 5672 5673

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/9443'

ENTRYPOINT ["/opt/smalt/bin/smalt"]
CMD ["start"]
