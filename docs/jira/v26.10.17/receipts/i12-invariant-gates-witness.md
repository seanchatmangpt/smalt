# I12 Witness Receipt — invariant-gates (coordinator-run, verify-only)

Standing: **PASS**

Lane I12 (lease: `gates/`, verify-only — no gate re-runs, no git). Witness of the
coordinator's `just invariant-gates` run. Receipts read directly from
`tmp/invariant-gates/*-receipt.json` (fresh, dated 2026-10-17).

## Verdict lines (quoted from real file contents)

| Gate | File | Verdict line | Fixtures detected |
|---|---|---|---|
| cosmos-etag-cas | `cosmos-etag-cas-receipt.json` | `"verdict": "PASS"` | 7/7 `detected: true` |
| blob-worm | `blob-worm-receipt.json` | `"verdict": "PASS"` | 6/6 `detected: true` |
| ledger-chain | `ledger-chain-receipt.json` | `"verdict": "PASS"` | 6/6 `detected: true` |
| queue-capacity | `queue-capacity-receipt.json` | `"verdict": "PASS"` | 3/3 `detected: true` |
| lock-clamp | `lock-clamp-receipt.json` | `"verdict": "PASS"` | 4/4 `detected: true` |
| appconfig-etag-cas | `appconfig-etag-cas-receipt.json` | `"verdict": "PASS"` | 6/6 `detected: true` |

**6/6 verdicts PASS. Every fixture across all gates `detected: true` (32/32 negative
fixtures).** Each positive check also `"positive": "PASS"`.

## Notes

- `cosmos-etag-cas` (the gate that FAILED at 13:28 under contention) passes quiet in
  this run: `"date": "2026-10-17"`, `"elapsed_s": 2.003`, all 7 fixtures
  (`two-winners`, `no-winner`, `etag-not-refreshed`, `stale-write-accepted`,
  `etag-unstable-reread`, `all-empty-race-codes`, `bad-etag-format`) detected:true,
  verdict PASS.
- `tmp/invariant-gates/bounds-receipt.json` is present but is a different schema
  (`smalt-bounds-receipt/v1`, dated 2026-10-15) — the bounds census, not one of the 6
  gate receipts; not counted here.
- Fixture `detected: true` semantics: the gate's mutated observation was REFUSED by the
  subject, i.e. the negative fixtures are non-vacuous (a gate that cannot detect is the
  failure).
