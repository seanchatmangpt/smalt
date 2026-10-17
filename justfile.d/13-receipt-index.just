# 13-receipt-index — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# Regenerate the manufacturing-receipt index (RECEIPTS.md + receipts/INDEX.md).
[no-cd]
receipt-index:
    python3 scripts/receipt_index.py

# Drift check: snapshot committed index, regenerate ONCE, diff against committed,
# restore committed bytes (even on drift). Fails loudly on any drift.
[no-cd]
receipt-index-check:
    #!/bin/sh
    set -e
    R=docs/jira/v26.10.14
    tmp=$(mktemp -d)
    trap 'cp "$tmp/RECEIPTS.md" '"$R"'/RECEIPTS.md; cp "$tmp/INDEX.md" '"$R"'/receipts/INDEX.md; rm -rf "$tmp"' EXIT
    cp "$R/RECEIPTS.md" "$tmp/RECEIPTS.md"
    cp "$R/receipts/INDEX.md" "$tmp/INDEX.md"
    python3 scripts/receipt_index.py >/dev/null
    if diff -u "$tmp/RECEIPTS.md" "$R/RECEIPTS.md" && diff -u "$tmp/INDEX.md" "$R/receipts/INDEX.md"; then
        echo "receipt-index: clean (committed index matches regeneration)"
    else
        echo "receipt-index: DRIFT — committed index does not match regeneration (restored committed bytes)" >&2
        exit 1
    fi

# WIRED-STAGE NOTE (R148): `receipt-index-check` is wired into `verify-all`
# (scripts/verify_all.sh, after naming-sweep, before invariant-gates).
# `receipt-durability-gate` is intentionally NOT wired: it stays informational
# until the tree's uncommitted receipt files are committed and the ~22 SUSPECT
# receipts are cleaned — wiring it now would make verify-all fail on known,
# pre-existing tree state, not on new drift.

# Receipt durability gate: fail-closed on (1) untracked receipt/sdk-result files
# not committed to git, (2) any SUSPECT-flagged receipts in the scan.
# Snapshot/restores RECEIPTS.md + INDEX.md bytes (receipt_index.py writes them
# as a side effect) so the gate itself is read-only on the tree.
[no-cd]
receipt-durability-gate:
    #!/bin/sh
    set -e
    R=docs/jira/v26.10.14
    fail=0

    # 1. Untracked receipt files (?? in porcelain)
    untracked=$(git status --porcelain -- \
        "$R/receipts" "$R/sdk-results" docs/jira/v26.10.16/receipts | grep '^??' || true)
    if [ -n "$untracked" ]; then
        echo "receipt-durability-gate: UNTRACKED receipt files (must be committed):" >&2
        echo "$untracked" >&2
        n=$(printf '%s\n' "$untracked" | wc -l | tr -d ' ')
        echo "receipt-durability-gate: untracked count = $n" >&2
        fail=1
    else
        echo "receipt-durability-gate: untracked receipts: none"
    fi

    # 2. SUSPECT count from receipt_index.py (snapshot/restore its outputs)
    tmp=$(mktemp -d)
    trap 'cp "$tmp/RECEIPTS.md" '"$R"'/RECEIPTS.md; cp "$tmp/INDEX.md" '"$R"'/receipts/INDEX.md; rm -rf "$tmp"' EXIT
    cp "$R/RECEIPTS.md" "$tmp/RECEIPTS.md"
    cp "$R/receipts/INDEX.md" "$tmp/INDEX.md"
    out=$(python3 scripts/receipt_index.py)
    suspects=$(printf '%s' "$out" | sed -n 's/.*suspects=\([0-9]*\).*/\1/p')
    if [ -n "$suspects" ] && [ "$suspects" -gt 0 ]; then
        echo "receipt-durability-gate: SUSPECT count = $suspects (receipts asserting results with no real output):" >&2
        printf '%s\n' "$out" | grep 'SUSPECT:' >&2
        fail=1
    else
        echo "receipt-durability-gate: SUSPECT count = 0"
    fi

    if [ "$fail" -ne 0 ]; then
        echo "receipt-durability-gate: FAIL" >&2
        exit 1
    fi
    echo "receipt-durability-gate: PASS"
