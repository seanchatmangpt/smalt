# 14-sdk-matrix — SDK coverage matrix (DoD-14)
# Mechanical surface-inventory + both-language cell gate per milestone
# window (every docs/jira/vX carrying a KNOWN_DIVERGENCES.md).

# Compile the SDK coverage matrix; exit 0 only when every cell in every
# window is pass-or-registered (no MISSING, no UNREGISTERED-GAP).
sdk-matrix:
    python3 scripts/sdk_coverage.py

# Regenerate docs/jira/v<win>/SDK_MATRIX.md for every window (same
# compiler, md artifact).
sdk-matrix-md:
    python3 scripts/sdk_coverage.py && \
      test -f docs/jira/v26.10.14/SDK_MATRIX.md && \
      test -f docs/jira/v26.10.16/SDK_MATRIX.md

# AZB-20 — unmodified Microsoft SDK interop per plane profile (SMALT_PLANES).
# RETIRED (v26.10.19 reset): test/sdk-full/azb20/run.mjs deleted at 64f6099.
# Successor: verification/ts plane-profile interop (V261019-08). LOUD no-op
# (exit 1) until then.
azsim-sdk:
    #!/usr/bin/env bash
    echo "[RETIRED] azsim-sdk: test/sdk-full/azb20 deleted at 64f6099; successor = verification/ts plane-profile interop (V261019-08). Exit 1 until it lands."
    exit 1
