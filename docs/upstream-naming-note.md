# Upstream Naming Note — Neutral Image-Reference Contract (upstream)

Recorded by upstream fan-out lane 18 (2026-10-24). Docs only; no smalt code
was touched.

## Contract

upstream refers to this repo's substrate image through a neutral variable,
`$SOVEREIGN_IMAGE`, defaulting to `smalt:local`. The upstream repo (smalt)
may rename its image or tag whenever ready — upstream never hardcodes the
name again.

## Where it lives in upstream

- `Justfile`: `SOVEREIGN_IMAGE := env_var_or_default("SOVEREIGN_IMAGE", "smalt:local")`
  — consumed by the `smalt-image` / `smalt-load` recipes.
- `infra/docker/sovereign-backend.yaml`: the container `image:` line carries
  the same value as a documented `$SOVEREIGN_IMAGE` default (plain `kubectl
  apply` does not substitute; override via sed/kustomize before apply).
- `docs/how-to/deploy-to-kind.md`: build/load commands parameterized as
  `"${SOVEREIGN_IMAGE:-smalt:local}"`.

## Exact upstream seams consumed (the full neutral surface)

1. **Image reference** — `$SOVEREIGN_IMAGE` (default `smalt:local`), as above.
2. **Ports** — 9443 (HTTPS main), 8443 (HTTP main), 9444 (HTTPS TLS twin),
   5672/5673 (AMQP pair), per `infra/docker/sovereign-backend.yaml`
   Services/StatefulSet and probes.
3. **Env contract** — neutral `AZURE_*` variable names in the ConfigMap
   (`sovereign-backend-env`); the in-image `SMALT_*` translation layer is
   smalt's own internal contract and is never referenced by name from
   upstream operators. Playground legs set the neutral
   `AZURE_PROVIDER_MODE=emulator` in `infra/docker/kind-playground.yaml`
   (valid values `emulator|live` per the upstream provider-mode seam,
   `playground/src/lib/azure-provider/mode.ts`; the legacy
   `ATHENA_AZURE_PROVIDER_MODE` spelling survives only as a compatibility
   alias in `docs/how-to/azure-provider-modes.md`).
4. **Health probe path** — `/.well-known/health/ready` and
   `/.well-known/health/live` on port 9443.

## Neutral-tag build recipe upstream (2026-10-25, R10)

smalt now emits the identical release image under the neutral tag via
`just sovereign-image` (`justfile.d/55-sovereign-image.just`):
`docker build -f Dockerfile.smalt --target release -t sovereign:local .`
from the checkout root. Identical contents to `smalt:local` — tag-only
delta. upstream's `SOVEREIGN_IMAGE` default remains `smalt:local` until the
flip procedure in upstream `docs/how-to/deploy-to-kind.md` ("Flipping to the
neutral `sovereign:local` tag") is run (build new tag → kind load → apply
with `SOVEREIGN_IMAGE=sovereign:local` → rollout status).

## Falsifier / gate

`grep -rn 'smalt:local' <upstream-checkout>/Justfile <upstream-checkout>/infra/`
must return only the `SOVEREIGN_IMAGE` default line(s) — no other hardcoded
image references. If the upstream rename lands, upstream changes one env var
(or one manifest default), not code.
