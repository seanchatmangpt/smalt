# BK-TRIO — seal gate re-runs, post-WRAP3 receipt wave

Standing: **ALIVE**
Context: solo
Date: 2026-10-22
Lane: BK-TRIO (read-only verify; generated indexes regenerated, left uncommitted)

## Scope

Fresh re-run of the seal's three cheap gates after ~30 receipts landed since
BK-WRAP3, plus kd_flip census and the VALIDATION.md PENDING check.

## 1. receipt_index regen — exit 0

```
receipts=1514 sdk=61 total=1575 suspects=9
  SUSPECT: bkaud2-lane-accounting.md (standing ALIVE)
  SUSPECT: bkbmir-jsonl-mirrors.md (standing ALIVE)
  SUSPECT: bkbmir2-mirror-wave2.md (standing PARTIAL_ALIVE)
  SUSPECT: bkclean3-reclaim.md (standing ALIVE)
  SUSPECT: bkdrain-monitor.md (standing ALIVE)
  SUSPECT: bkdrain2-monitor.md (standing ALIVE)
  SUSPECT: bkmcpsha-sha-fix.md (standing ALIVE)
  SUSPECT: bkp20-export-disposition.md (standing UNSUPPORTED)
  SUSPECT: bkqmon-window.md (standing UNKNOWN)
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.14/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.17/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.17/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.18/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.18/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.19/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.19/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.20/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.20/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.21/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.21/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.22/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.22/receipts/INDEX.md
EXIT=0
```

Suspects = 9, matching the expected ~10 post-REWIT3/BK-BQUIET waves.

Regenerated indexes that diffed (left **uncommitted** — other lanes
mid-landing: `lib/smalt/arm_gateway/router.ex`, `test/internal/kafka_exp4_court_test.exs`,
`c8-chaos-cross.jsonl` in flight):

```
 docs/jira/v26.10.14/RECEIPTS.md       | 1 +
 docs/jira/v26.10.14/receipts/INDEX.md | 4 ++--
 docs/jira/v26.10.22/RECEIPTS.md       | 1 +
 docs/jira/v26.10.22/receipts/INDEX.md | 4 ++--
 4 files changed, 6 insertions(+), 4 deletions(-)
```

## 2. just docs-dod-check — exit 0

All 63 checks OK; kd-receipt-fence embedded leg:

```
kd-receipt-fence: checked 753 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (422 cites, 6 typed-gap skips) -> OK
DOD_EXIT=0
```

Note: `just kd_receipt_fence` is not a standalone recipe (exit 1, "justfile
does not contain recipe"); the fence runs inside docs-dod-check (exit 0), and
standalone via `python3 scripts/kd_receipt_fence.py` (same OK line).

## 3. kd_flip census (read-only, no flags) — exit 0

```
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused
```

## 4. VALIDATION.md PENDING check

`docs/jira/v26.10.22/VALIDATION.md` row-level PENDING cells: **0** (confirmed
in-file at §4 line 102: "Row-level PENDING cells in this board: **0**").
Remaining PENDING mentions are lineage prose plus the Gate-3 seal cell typed
PARTIAL_ALIVE with PENDING-GATE residue cited, not a PENDING cell.

## Verdict

All three seal gates green post-WRAP3 receipt wave; index regen diff is
coordinator-integration material. Standing ALIVE.
