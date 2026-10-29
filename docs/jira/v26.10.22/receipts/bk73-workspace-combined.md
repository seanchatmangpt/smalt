# BK-73 — Combined-tree workspace verification

**Standing**: ALIVE
- **Context**: full
- **Subject**: /Users/sac/smalt @ 1e82d0d (main, combined tree: PAT-A/B/E, SPOF-4, W3C-E, SYNC-2 landed on workspace/)
- **Date**: 2026-10-21

## Verdict

The COMBINED workspace tree is proven: lint, build, ws-court, all seven node
courts, and both new gates pass on the merged tree with one fix (below). No
regression from combining the lane landings.

## Fix applied (real regression)

`workspace/.spof4-court-XFGUrr/` — a stale spof4-court temp outDir from a
killed in-flight run — was present on the tree and ws-lint failed on it (10
`no-require-imports` errors in its compiled `out/*.js`). Removed the stale
dir; spof4-court.mjs already cleans up on normal exit (lines 91/239/468), so
no script change was needed. **Pre-existing in-flight artifact, not a
regression from the combined landings.**

## Per-gate table

| Gate | Exit | Count | Notes |
|---|---|---|
| `just ws-lint` | 0 | 0 errors, 43 warnings (pre-existing) | was exit 1 before stale-dir fix |
| `just ws-build` | 0 | build clean | |
| `just ws-court` (e2e-court.mjs) | 0 | PASS=62 FAIL=0 SKIP=2 | SKIPs: DOM/Web Serial not executable in node; live leg needs :3100 server |
| codec-court.mjs | 0 | 11 PASS / 0 FAIL | |
| dom-contract-court.mjs | 0 | 16 PASS / 0 FAIL | |
| snapback-court.mjs | 0 | 10 [ok] / 0 fail | "all assertions passed" |
| receipt-court.mjs | 0 | 20 [ok] / 0 fail | "all assertions passed" |
| tab-lease-court.mjs | 0 | 7 PASS / 0 FAIL | |
| spof4-court.mjs | 0 | 19 PASS / 0 FAIL | |
| patterns-court (just) | 0 | 13 PASS / 3 SKIP / 0 FAIL | |
| `just private-trip` | 0 | clean, 908 source files scanned | |
| `just heir-guard` | 0 | 38 heir :ets.new sites, 38 guarded, 0 failing | |

## Environment note

Another lane committed during this run (HEAD moved d86356b → 1e82d0d); all
gates ran on the post-1e82d0d tree except ws-lint/ws-build/ws-court, which ran
on the d86356b workspace state — workspace/ was untouched between the two
HEADs, so the proofs are on identical workspace content. `git status workspace/`
at end of run: only `M workspace/scripts/spof4-court.mjs` (in-flight lane
snapshot, untouched by this lane).
