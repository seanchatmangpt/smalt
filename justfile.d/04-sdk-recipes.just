# 04-sdk-recipes — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
#
# REPOINTED (BK-ENG0, v26.10.22): the verification/ successors exist on disk
# (verification/ts with real @azure/* SDKs, verification/py pytest suite) —
# the loud-retirement stubs are gone; the recipes run the real suites and
# pass their exit codes through per the documented contract:
#   ts lane    exit 0 pass / 1 test fail / 2 substrate down / 3 harness / 124 watchdog
#   census     exit 0 pass / 1 census fail / 2 substrate down / 3 harness(=SKIP)
#   py lane    exit 0 pass / 1 probe fail / 2 substrate timeout / 3 lock failure
# (subjects deleted at 64f6099; repoint contract per the module header.)

# ---------------------------------------------------------------- sdk-ts ----
sdk-ts:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "$(git rev-parse --show-toplevel)/verification/ts"
    [ -f run-all.mjs ] || { echo "[sdk-ts] verification/ts/run-all.mjs missing" >&2; exit 3; }
    exec node run-all.mjs

# ------------------------------------------------------------- sdk-census ----
sdk-census:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "$(git rev-parse --show-toplevel)/verification/ts"
    [ -f census.test.cjs ] || { echo "[sdk-census] census.test.cjs missing" >&2; exit 3; }
    exec node --test census.test.cjs

# ---------------------------------------------------------------- sdk-py ----
sdk-py:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "$(git rev-parse --show-toplevel)"
    [ -f verification/py/run.sh ] || { echo "[sdk-py] verification/py/run.sh missing" >&2; exit 3; }
    exec bash verification/py/run.sh

# --------------------------------------------------------------- sdk-all ----
# sdk-all keeps its contract: any member FAIL(1) -> exit 1 (3=SKIP allowed).
sdk-all:
    #!/usr/bin/env bash
    set -u
    cd "$(git rev-parse --show-toplevel)"
    just sdk-ts;      ts=$?
    just sdk-census;  cy=$?
    just sdk-py;      py=$?
    echo ""
    echo "sdk-all SUMMARY:"
    [ "$ts" -eq 0 ] && v=PASS || v="FAIL($ts)"; echo "  sdk-ts      $v"
    [ "$cy" -eq 0 ] && v=PASS || { [ "$cy" -eq 3 ] && v=SKIP || v="FAIL($cy)"; }; echo "  sdk-census  $v"
    [ "$py" -eq 0 ] && v=PASS || { [ "$py" -eq 3 ] && v=SKIP || v="FAIL($py)"; }; echo "  sdk-py      $v"
    if [ "$ts" -eq 1 ] || [ "$cy" -eq 1 ] || [ "$py" -eq 1 ]; then exit 1; fi
    exit 0
