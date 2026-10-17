# Receipt: r214 — SUSPECT remainder triage (docs lane, 2026-10-16)

- **Standing: PASS** — counts re-derived from `receipt_index.py` at execution
  time; every disposition names the on-disk receipt and was verified by reading
  the file header this session.
- Close condition: NEXT_WINDOW.md section 3 — "a docs-lane receipt naming each
  remaining SUSPECT receipt with its disposition (historical-accept |
  leave-flagged) and the receipt_index.py summary line embedded as evidence".

## Evidence (embedded real output)

```
$ python3 scripts/receipt_index.py
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.14/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/receipts/INDEX.md
  SUSPECT: 06-blob-x-ms-date-unvalidated.md (standing UNSUPPORTED)
  SUSPECT: a2-cas-contention.md (standing UNKNOWN)
  SUSPECT: bench-02-blob-ts.md (standing UNKNOWN)
  SUSPECT: bench-03-cosmos-ts.md (standing ALIVE)
  SUSPECT: bench-04-messaging-ts.md (standing UNKNOWN)
  SUSPECT: bench-05-python-mirror.md (standing UNKNOWN)
  SUSPECT: bench-12-consolidation.md (standing UNKNOWN)
  SUSPECT: c4-kv-cosmos.md (standing ALIVE)
  SUSPECT: c8-chaos-cross.md (standing UNKNOWN)
  SUSPECT: errc4-hdr.md (standing ALIVE)
  SUSPECT: fin24-p5-doc.md (standing ALIVE)
  SUSPECT: fin30-landing.md (standing UNKNOWN)
  SUSPECT: fin32-wrap-final.md (standing PARTIAL_ALIVE)
  SUSPECT: fin33-planning-summary.md (standing PARTIAL_ALIVE)
  SUSPECT: lc1-8hop-tax-chain.md (standing ALIVE)
  SUSPECT: lc2-tco-ledger.md (standing UNKNOWN)
```

Honest census: **16 SUSPECT**, all v26.10.14 window-era records. Prior ledger
drafts cited 21/23; 4 re-witnesses + 2 SUPERSEDED flips landed in-window,
moving the remainder to 16. Counts re-derived at execution time, not cited
from the ledger (receipt cited stale-by-default).

## Triage table

All files under `docs/jira/v26.10.14/receipts/`; session-era records are not
edited, so every disposition leaves the standing as-is.

| Receipt | Standing | Disposition |
|---|---|---|
| 06-blob-x-ms-date-unvalidated.md | UNSUPPORTED | historical-accept (typed-UNSUPPORTED record, lane-13 consumption) |
| a2-cas-contention.md | UNKNOWN | historical-accept (session-era bench/EDA record) |
| bench-02-blob-ts.md | UNKNOWN | historical-accept (session-era bench numbers) |
| bench-03-cosmos-ts.md | ALIVE | historical-accept (standing present; output missing) |
| bench-04-messaging-ts.md | UNKNOWN | historical-accept (session-era bench numbers) |
| bench-05-python-mirror.md | UNKNOWN | historical-accept (session-era bench numbers) |
| bench-12-consolidation.md | UNKNOWN | **leave-flagged** — SUPERSEDED banner in-body (bench-07/bench-08 re-witnessed 2026-10-16); no indexer change |
| c4-kv-cosmos.md | ALIVE | historical-accept (standing present; output missing) |
| c8-chaos-cross.md | UNKNOWN | historical-accept (session-era chaos overlay) |
| errc4-hdr.md | ALIVE | historical-accept (standing present; output missing) |
| fin24-p5-doc.md | ALIVE | historical-accept (doc-recovery record) |
| fin30-landing.md | UNKNOWN | historical-accept (commit-executor closeout record) |
| fin32-wrap-final.md | PARTIAL_ALIVE | **leave-flagged** — SUPERSEDED banner in-body (fin33-planning-summary); no indexer change |
| fin33-planning-summary.md | PARTIAL_ALIVE | historical-accept (planning summary, no exec output by design) |
| lc1-8hop-tax-chain.md | ALIVE | historical-accept (lifecycle harness record) |
| lc2-tco-ledger.md | UNKNOWN | historical-accept (session-era ledger record) |

Split: **14 historical-accept + 2 leave-flagged (SUPERSEDED in-body) = 16.**
The indexer SUPERSERVED/SUPERSEDED status remains out of scope (code change,
needs its own WO) per NEXT_WINDOW section 3; r130-r140-not-receipted.md keeps
its carry-record disposition per section 3b.

- Falsifier: `python3 scripts/receipt_index.py | grep -c SUSPECT` must still
  read 16 (or lower only via re-witness/supersede receipts, never silent drop).
