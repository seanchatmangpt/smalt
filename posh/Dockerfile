# posh sidecar image — POSH-005 sidecar mode (lane F14).
# UDS-only: no EXPOSE, socket shared with the app container via an emptyDir
# at /posh/run. Distroless static base, non-root, read-only rootfs.
#
# Build:  docker build -t posh:sidecar posh/
# Load:   kind load docker-image posh:sidecar --name smalt
# See:    k8s/posh-sidecar.yaml

# --- builder: static linux binary, CGO off ---------------------------------
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=sidecar-$(date -u +%Y%m%d)" \
    -o /out/posh ./cmd/posh

# --- tiny static shell for HEALTHCHECK (distroless has none) ---------------
FROM busybox:1.36 AS shell

# --- runtime ---------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/posh /bin/posh
COPY --from=shell /bin/busybox /bin/sh
# UDS-only membrane: no ports. Health = socket exists.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/bin/sh", "-c", "[ -S /posh/run/posh.sock ]"]
ENTRYPOINT ["/bin/posh", "-config", "/etc/posh/posh.yaml"]
