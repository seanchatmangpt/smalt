# posh sidecar image — POSH-005 sidecar mode (lane F14).
# UDS-only: no EXPOSE, socket shared with the app container via an emptyDir
# at /posh/run. Pure distroless: NO shell — every exec path (container
# command, k8s probes) must invoke /bin/posh directly; config comes from a
# ConfigMap mounted at /etc/posh (distroless has no sh to write one).
#
# Build:  docker build -t posh:sidecar posh/
# Load:   kind load docker-image posh:sidecar --name smalt
# See:    k8s/posh-sidecar.yaml

# --- builder: static linux binary, CGO off, BuildKit cache mounts ---------
FROM golang:1.26-alpine AS build
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -buildid= -X main.version=sidecar-$(date -u +%Y%m%d)" \
    -o /out/posh ./cmd/posh

# --- runtime ---------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/posh /bin/posh
# UDS-only membrane: no ports, no HEALTHCHECK (no shell in distroless;
# k8s exec probes own health: /bin/posh -version, or a socket test).
ENTRYPOINT ["/bin/posh", "-config", "/etc/posh/posh.yaml"]
