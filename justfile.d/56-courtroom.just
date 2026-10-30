# 56-courtroom — T03 consumer court: courtroom-platform-az on smalt, zero cloud.
# `just courtroom-court` runs the full end-to-end court (legs 1-3; exit
# 0 pass / 1 assert fail / 2 substrate never up / 3 loud skip).
# `just courtroom-check` runs leg 1 only (materialize + node 22 npm ci +
# npm run check) — independent of smalt.

# Full consumer court: courtroom-platform-az on smalt (redis wire + saml idp).
courtroom-court:
    bash scripts/courtroom_consumer_court.sh

# Leg 1 only: materialize consumer repo into /tmp/courtroom-void/<sha> and check it.
courtroom-check:
    #!/usr/bin/env bash
    set -uo pipefail
    SCRATCH=/tmp/courtroom-void/$(git -C /Users/sac/cai/courtroom-platform-az rev-parse HEAD)
    rm -rf "$SCRATCH" && mkdir -p "$SCRATCH"
    git -C /Users/sac/cai/courtroom-platform-az archive HEAD | tar -x -C "$SCRATCH"
    bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && cd '$SCRATCH' && npm ci --no-audit --no-fund && npm run check"
