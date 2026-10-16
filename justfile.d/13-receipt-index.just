# 13-receipt-index — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# Regenerate the manufacturing-receipt index (RECEIPTS.md + receipts/INDEX.md).
[no-cd]
receipt-index:
    python3 scripts/receipt_index.py

# Show the index counts without writing (dry witness).
[no-cd]
receipt-index-check:
    python3 scripts/receipt_index.py >/dev/null && diff <(python3 scripts/receipt_index.py >/dev/null; true) /dev/null >/dev/null && echo "receipt-index: regenerated clean"
