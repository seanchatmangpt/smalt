# Receipt: i29-doctor-dod-gapcensus — doctor_dod.py GAP-census retirement

Date: 2026-10-18 · Context: solo(checkpoint2 census follow-up) · Standing: ALIVE

## Change

`scripts/doctor_dod.py` retires lane-13's stale GAP census in favor of the
live-open register:

- `EXPECTED_TOKENS` drops 4 retired tokens (blob-error-envelope-json,
  cosmos-sql-translator-absent, ledger-lazy-create-default,
  eventhubs-partition-metadata-absent,
  eventhubs-consumer-group-enumeration-absent) and adds
  `GAP(blob-x-ms-date-unvalidated)`.
- Counts updated `5 CLOSED + 9 UNSUPPORTED` → `3 CLOSED + 5 UNSUPPORTED`,
  with an inline NOTE naming each retired token and its closure receipt.
- check 4 rides ADR-PY-002 (`.venv-cli` instead of bare `.venv`).

## Gate output (exit 0)

```
$ just doctor-dod; echo EXIT=$?
doctor_dod (DoD-5) — repo /Users/sac/smalt
INFO  substrate lock: lock present AND live listeners 9443 pid=61023 (ssh), 8443 pid=61023 (ssh) — not stale
WARN  lane build roots: 9 lane build-root lease(s) at repo root, total 3.0 GiB; remediation: `just lane-clean`
INFO  workspace: node_modules present
INFO  workspace: package.json parses (22 deps)
INFO  workspace: @azure/arm-resources pin '^8.0.0' sane (no ^21.x)
INFO  smalt-cli: .venv present (python: /Users/sac/smalt/smalt-cli/.venv-cli/bin/python)
INFO  smalt-cli: py_compile clean over 12 files
INFO  receipts: _LANES.md references no receipts/<lane>.md files (nothing to fail on)
INFO  receipts freshness: 1/161 file(s) inside the 24h session window
INFO  envelope/defect cross-check: all 5 expected gap tokens present
INFO  gap register sync: 3 'CLOSED 2026-10-15' stamps; 5 distinct live GAP(...) tokens in WIRE_PARITY.md (lane-13 census: 3 CLOSED + 5 UNSUPPORTED)
summary: 0 FAIL, 1 WARN (exit 0 unless FAIL fired)
EXIT=0
```

1 WARN is pre-existing (lane build-root leases, remediation `just lane-clean`);
not introduced by this diff.

## Verdict

KEEP. Gate green, census now synced to the live WIRE_PARITY.md register.
