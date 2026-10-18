# Build receipt — smalt:local / smalt-burn:latest (2026-10-18, AZB-01)

Canonical build commands (run from repo root):

```sh
# release target (image pin)
docker build -f docker/Dockerfile -t smalt:local . \
  --build-context ash_r2rml=/Users/sac/ash_r2rml

# test target (burn lanes)
docker build -f docker/Dockerfile --target test -t smalt-burn:latest . \
  --build-context ash_r2rml=../ash_r2rml
```

Full command output, layer-cache evidence, anti-vacuity mutation, and disclosures:
`docs/jira/v26.10.18/receipts/azb-01-image-pin.md` (standing ALIVE).

## Quick facts

- Base: `hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9@sha256:29c51579d430b307d4f6182775373bb18c9...`
  (digest-pinned; multi-arch index; linux/arm64 leaf 528a493d…).
- Images (2026-10-18): `smalt:local` `sha256:d7e21e70c324…a4dc9e`,
  `smalt-burn:latest` `sha256:7557d29a3706…7aae184`.
- Label `org.smalt.subject=29bb0371426a270c9c9ac2dc483b7e2a9d226938`
  (build-arg `SUBJECT_SHA` override; exported at runtime as
  `SMALT_BURN_SUBJECT_SHA` for AZB-03 emitters).
- In-image TLS: minted at build by `/usr/local/bin/gen_dev_cert_linux.sh`
  → `/smalt/.smalt/tls/{ca-cert,ca-key,dev-cert,dev-key}.pem`, CA:TRUE anchor +
  CA:FALSE serverAuth leaf, chain verifies in-image.
- Warm deps layer: `mix.exs`+`mix.lock` → `deps.get` → `MIX_ENV=test`/`prod`
  `deps.compile` before any `lib/` copy; a `lib/`-only delta leaves all deps
  steps CACHED; any `mix.lock` byte move invalidates the layer (witnessed).
