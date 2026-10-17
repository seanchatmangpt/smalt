# Receipt — R27 (session-ledger attempt entry, airgap seam)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `workspace/lib/copilot/session-ledger.ts` — R27: a ledger attempt entry is
  appended BEFORE the fetch with outcome `ok | refused-airgap | fetch-error`,
  excluded from `computeHash`
- `workspace/scripts/e2e-court.mjs:317` — court leg "session-ledger chain +
  guardedFetch refusal (zero-actuation seam)"

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ cd /Users/sac/smalt/workspace && npm run lint
✖ 13 problems (0 errors, 13 warnings)
LINT_EXIT=0

$ cd /Users/sac/smalt/workspace && NODE_PATH="/Users/sac/smalt/workspace/node_modules" node scripts/e2e-court.mjs
# court verdict
# PASS=42 FAIL=0 SKIP=1
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
COURT_EXIT=0
```

The SKIP is the loud, documented DOM-rendering skip (type-layer witnessed),
not a hidden failure. The live leg ran: ARM read-only probe returned 200.
