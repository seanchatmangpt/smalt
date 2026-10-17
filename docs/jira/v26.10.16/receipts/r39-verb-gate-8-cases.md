# Receipt — R39 (copilot verb-gate: read-marker semantics over full URL, 8-case court)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `workspace/lib/copilot/verb-gate.ts` — READ_PATTERNS now tested against the
  FULL URL (query-anchored read markers were dead when matched against the
  stripped pathname); dead read-allowlist branch removed. Court cases mirror
  `workspace/scripts/e2e-court.mjs` lines 275-292.

## Verification (2026-10-15, W2 docs lane, unedited output; verb-gate.ts compiled standalone with workspace tsc, then the 8 e2e-court cases executed in node)

```
tsc-exit=0
PASS: 8/8 verb-gate cases
gate-exit=0
```

Cases: PUT/DELETE/POST/PATCH on the VM URL refused; GET on the VM URL and
GET on the `/read` URL pass; suggestion-layer `.../write` refused,
`.../read` passes.
