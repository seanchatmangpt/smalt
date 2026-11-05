# 64-receipts — Gate 3 receipt-standing lint (v26.11.5 lane L24)
# Port of cgap scripts/receipt_standing_lint.py (ggen Gate-3 ancestor).
# Composes with 13-receipt-index (evidence census) — this checks parseable
# standing lines in the closed vocabulary; receipt_index checks evidence.

# Census + fail-closed lint: every receipt carries a parseable standing line
# in the closed standing vocabulary. Exit 1 names each missing/bad file.
[no-cd]
receipt-standing-lint:
    python3 scripts/receipt_standing_lint.py

# Print proposed Standing insertions as diffs; never writes.
[no-cd]
receipt-standing-backfill-diff:
    python3 scripts/receipt_standing_lint.py --backfill
