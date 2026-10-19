# 04-sdk-recipes — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
#
# v26.10.19 staleness-repair lane: the SDK subjects (test/sdk-full,
# test/sdk-smoke, test/sdk-python) were DELETED at 64f6099. Until the
# verification/ successors land (V261019-08 ts / V261019-09 py), every
# recipe here is a LOUD no-op: exit 1, message naming the successor —
# never a silent pass. Repoint the moment verification/ts, verification/py
# exist on disk.
#
# Exit contracts to restore when repointed:
#   ts lane    exit 0 pass / 1 test fail / 2 substrate down / 3 harness / 124 watchdog
#   census     exit 0 pass / 1 census fail / 2 substrate down / 3 harness(=SKIP)
#   py lane    exit 0 pass / 1 probe fail / 2 substrate timeout / 3 lock failure


# ---------------------------------------------------------------- sdk-ts ----
sdk-ts:
    #!/usr/bin/env bash
    echo "[RETIRED] sdk-ts: test/sdk-full deleted at 64f6099; successor = verification/ts (V261019-08). Exit 1 until it lands."
    exit 1

# ------------------------------------------------------------- sdk-census ----
sdk-census:
    #!/usr/bin/env bash
    echo "[RETIRED] sdk-census: test/sdk-smoke census subject deleted at 64f6099; successor = verification/ts census (V261019-08). Exit 1 until it lands."
    exit 1

# ---------------------------------------------------------------- sdk-py ----
sdk-py:
    #!/usr/bin/env bash
    echo "[RETIRED] sdk-py: test/sdk-python deleted at 64f6099; successor = verification/py (V261019-09). Exit 1 until it lands."
    exit 1

# --------------------------------------------------------------- sdk-all ----
# sdk-all keeps its contract: any member FAIL(1) -> exit 1 (3=SKIP would be
# allowed, but retired members exit 1, so sdk-all is honestly red).
sdk-all:
    #!/usr/bin/env bash
    set -u
    cd "$(git rev-parse --show-toplevel)"
    just sdk-ts;      ts=$?
    just sdk-census;  cy=$?
    just sdk-py;      py=$?
    echo ""
    echo "sdk-all SUMMARY:"
    [ "$ts" -eq 0 ] && v=PASS || v="FAIL($ts)"; echo "  sdk-ts      $v (RETIRED — successor verification/ts, V261019-08)"
    [ "$cy" -eq 0 ] && v=PASS || { [ "$cy" -eq 3 ] && v=SKIP || v="FAIL($cy)"; }; echo "  sdk-census  $v (RETIRED — successor verification/ts census)"
    [ "$py" -eq 0 ] && v=PASS || { [ "$py" -eq 3 ] && v=SKIP || v="FAIL($py)"; }; echo "  sdk-py      $v (RETIRED — successor verification/py, V261019-09)"
    if [ "$ts" -eq 1 ] || [ "$cy" -eq 1 ] || [ "$py" -eq 1 ]; then exit 1; fi
    exit 0
