# 14-sdk-matrix — SDK coverage matrix (DoD-14)
# Mechanical surface-inventory + both-language cell gate over the
# v26.10.14 SDK validation receipts.

# Compile the SDK coverage matrix; exit 0 only when every cell is
# pass-or-registered (no MISSING, no UNREGISTERED-GAP).
sdk-matrix:
    python3 scripts/sdk_coverage.py

# Regenerate docs/jira/v26.10.14/SDK_MATRIX.md (same compiler, md artifact).
sdk-matrix-md:
    python3 scripts/sdk_coverage.py && test -f docs/jira/v26.10.14/SDK_MATRIX.md
