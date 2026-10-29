# 55-sovereign-image — neutral-tag image build (R10 lane, 2026-10-25)
#
# Image/recipe name neutralization prep: emit the substrate release image
# under the neutral tag `sovereign:local` — same Dockerfile.smalt release
# target athena's `just sovereign-image` builds, identical contents, tag
# only. This is a build-target NAME change, not a behavioral change; the
# legacy `smalt:local` tag continues to be produced by the same build and
# remains what the athena kind cluster currently has loaded.
#
# athena flips its `SOVEREIGN_IMAGE` default only after rebuilding+reloading
# (the flip procedure lives in athena docs/how-to/deploy-to-kind.md, and the
# neutral image-reference contract is recorded in
# docs/upstream-naming-note.md).

# Per same-checkout-fanout law 5: per-module prefixed variable.
SOVIMG_ROOT := justfile_directory()

# Build from the checkout root — Dockerfile.smalt expects the sibling build
# contexts (ash_r2rml / ash_graphlaw / ggen_igniter).
# Build the sovereign release image under the neutral tag `sovereign:local`
# (identical contents to `smalt:local`; tag-only delta).
sovereign-image:
    docker build -f Dockerfile.smalt --target release -t sovereign:local \
      --build-context ash_r2rml=$HOME/ash_r2rml \
      --build-context ash_graphlaw=$HOME/ash_graphlaw \
      --build-context ggen_igniter=$HOME/ggen_igniter {{SOVIMG_ROOT}}
