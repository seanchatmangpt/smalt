# 20-sobelow — static security analysis (ERRC lane 8 Raise, v26.10.14).
# First pass is non-blocking: this recipe RECORDS findings, does not gate.
# Triage: docs/jira/v26.10.14/receipts/errc8-sobelow.md

# Run sobelow static security scan over lib/ (non-blocking; prints triage pointer).
sobelow:
    @mix sobelow --config; echo "Note: non-blocking first pass — triage in docs/jira/v26.10.14/receipts/errc8-sobelow.md"
