# BK-114 — Verification re-runs at current HEAD

**Standing:** **PARTIAL_ALIVE** (8 of 9 checks re-witnessed PASS at HEAD; `just private-trip` FAIL — real regression, owner dispatch below)
Context: full
Date: 2026-10-21 · HEAD `ddfa61be8186e982886cb0f13eca797b3808ab09` (main) · dirty working set: `lib/smalt/data_plane/blob_error.ex`, `lib/smalt/data_plane/cosmos.ex`, `test/internal/bk104_debug_scratch_test.exs`, `test/internal/ja15_error_logger_court_test.exs` (BK-104/BK-70r in-flight lanes; none touch the checked surfaces' logic paths except as noted). No commit (per WO).

## Per-check results

| # | Check | Result | Exit | Passed-at SHA | Receipt | Note |
|---|---|---|---|---|---|---|
| 1 | `just private-trip` | **FAIL — real regression** | 1 | — | `bk54-private-trip-remediation.md` (ALIVE, PASS at ~879-file tree pre-`adecd7cd`) | 5 `[home-path]` hits in `workspace/scripts/sync-e2e-court.mjs` (lines 10, 12, 108, 109, 234). File last touched committed at `adecd7cd` (BK-106 sync-engine lane) — landed AFTER the BK-54 green. Refusal output: `PRIVATE-TRIP REFUSE: 5 hit(s) in 1 file(s)`. |
| 2 | `just heir-guard` | PASS (re-witnessed) | 0 | `ddfa61b` | `bk57-heir-guard.md` (census 37 sites at `2bcfe38`) | 36 heir `:ets.new` sites, 36 guarded, 0 failing. Count 37→36 vs receipt; the "38/38" in the dispatch brief is stale — receipt says 37. `cosmos.ex` line shift (2383→2385) is dirty-working-set line drift, no ets.new change in its diff. Count delta not triaged to the exact site; gate honest. |
| 3 | `just kd-stale` | PASS | 0 | `ddfa61b` | kd_flip register (`KNOWN_DIVERGENCES.md`) | `FLIP-PENDING-WITNESS: 0`. |
| 4 | `just patterns-court` | PASS (re-witnessed) | 0 | `ddfa61b` | PAT-D receipt (pattern court) | **13 PASS / 3 SKIP / 0 FAIL — matches expected exactly.** Browser tier PASSED (P1/P2/P3/P6 live on `next start` :46360) — PAT-D's discovery works. SKIPs: P4/P5/P9 (playwright absent under air-gap + live-server SYNC-1), unchanged class. |
| 5 | `just ws-lint` | PASS | 0 | `ddfa61b` | DoD lane module `02-workspace.just` | 0 errors / 45 warnings (no-unused-vars class, pre-existing). |
| 6 | `just ws-court` | PASS (re-witnessed) | 0 | `ddfa61b` | `e2e-court.mjs` verdict block | PASS=62 FAIL=0 SKIP=2 (SKIP: panel rendering type-layer; popcorn iframe src — no :3100 server, same class as prior runs). |
| 7 | codec court (node) | PASS | 0 | `ddfa61b` | `workspace/scripts/codec-court.mjs` | verdict PASS (0 failures); convoy codec + sabotage assertions hold (also witnessed by PAT P7/P11 legs). |
| 8 | dom-contract court (node) | PASS | 0 | `ddfa61b` | `workspace/scripts/dom-contract-court.mjs` | verdict PASS (0 failures). |
| 9 | snapback court (node) | PASS | 0 | `ddfa61b` | `workspace/scripts/snapback-court.mjs` | all assertions passed. |
| 10 | receipt court (node) | PASS | 0 | `ddfa61b` | `workspace/scripts/receipt-court.mjs` | all assertions passed (320/true verified-token, 0/false malformed). |

## FAIL classification — private-trip

Real regression, not an in-flight lane file: `workspace/scripts/sync-e2e-court.mjs` is
**committed** (`adecd7cd`, BK-106 tick checkpoint) and carries 5 absolute
`/Users/sac/smalt/...` literals (`[home-path]` class). BK-54's remediation reached
"clean (879 source files scanned)"; BK-106's landing reintroduced the class it
closed. **Owner dispatch: BK-106/SYNC lane owner** — fix is mechanical
(`import.meta.url`-derived ROOT per the BK-54 Class A pattern, 5 sites, 1 file).
Gate itself healthy: refusal fired fail-closed with per-line detail.

## Notes

- heir-guard count delta (37 receipt → 36 now) is noted, not triaged to the exact
  removed site; a follow-up can diff the BK-57 census table against the gate's
  per-site output. Gate exit 0 with 0 failing either way.
- patterns-court browser tier passing without playwright confirms PAT-D discovery
  works on the current tree (3 SKIPs are the documented air-gap/live-server class).
- The BK-54 ALIVE receipt's standing is now stale-as-of-HEAD (gate RED again);
  this receipt is the re-witness that re-opens it for the owner.
