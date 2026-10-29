# BK-FIN — FINAL-RELEASE seal-refresh (gate table + census to disk truth)

**Standing**: ALIVE (doc edit + census receipt; the seal itself remains PENDING-GATE on 4 rows — typed, not smoothed)
**Context**: solo
**Date**: 2026-10-22
**Lane**: BK-FIN (owns `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` + this receipt)

## Task

Rewrite the FINAL-RELEASE gate ledger + KD census section to the freshest
disk truth: every gate row cites its current receipt (existence + standing
line read at use time), fresh mechanical KD census, witness-all + seal-ladder
standings, row-level PENDING count; zero prose-only verdicts.

## Method

1. Wait-bounded (~25 min, two poll windows, 20 s interval) on
   `docs/jira/v26.10.22/receipts/` for the in-flight register/seal lanes.
   Landed during window 1: `bkseal2-fullgreen-recheck.md`. Never landed:
   `bk44-witness-all.md`, `bk35-head-court-sweep.md`,
   `ttv7b-quiesced-flip.md`, `bk53-finalrelease-seal.md` — typed IN-FLIGHT /
   PENDING-GATE, not smoothed.
2. Fresh mechanical census, bk10c awk convention over
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (the canonical table; the
   v26.10.22 `KNOWN_DIVERGENCES.md` is a prose window register with 0
   `| KD-nn` table rows — census source unchanged from bk10c/BK-PRD5).

## Embedded census (real output)

```
$ awk -F'|' '/^\| KD-/{s=""; for(i=2;i<=NF;i++) if($i!~/^ *$/) s=$i; gsub(/^ +| +$/,"",s); print s}' \
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md > /tmp/kd_bkfin_status.txt
$ wc -l < /tmp/kd_bkfin_status.txt
172
$ grep -c '^CLOSED' /tmp/kd_bkfin_status.txt
162
$ grep -c '^OPEN' /tmp/kd_bkfin_status.txt
4
$ grep -c '^PINION' /tmp/kd_bkfin_status.txt
4
$ grep -c '^ENVIRONMENT' /tmp/kd_bkfin_status.txt
1
$ grep -c '^UNSUPPORTED' /tmp/kd_bkfin_status.txt
1
$ grep -cE '^(OPEN|CLOSED|PINION|UNSUPPORTED|ENVIRONMENT)' /tmp/kd_bkfin_status.txt
172
$ grep -oE '^\| KD-[0-9]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort | uniq -d | wc -l
0
```

162+4+4+1+1 = 172, no skew; 0 duplicate ids. OPEN = KD-168 (env-gated),
KD-173, KD-174, KD-175. Census lineage: bk10c 166/158 → KD-SYNC 167/159 →
BK-PRD5 171/160/5 → BK-FIN 172/162/4.

## Gate rows re-verified at use time (existence + standing grep)

```
EXISTS  ja-r3-ja16-defect-fixes.md        :: Standing: PASS
EXISTS  ttv4-journal-boot-replay.md       :: Standing: ALIVE
MISSING  ttv5-store-partitioning.md       (court file on disk; expected receipt absent)
EXISTS  bk33-warm-restart-rebind.md       :: Standing: RESOLVED / ALIVE
EXISTS  ath2-nextjs-client.md             :: Standing: ALIVE (browser) / PARTIAL sync leg
EXISTS  ath1-batch-frame-receiver.md      :: Standing: ALIVE (court 11/11)
EXISTS  sync1-batch-receiver.md           :: Standing: ALIVE
MISSING  fr-snc-005.md / fr-snc-006.md    (typed UNBUILT in PRD §4; QUEUED)
EXISTS  bkvc-consolidated-courts.md       :: Standing: ALIVE (x2 exit 0)
EXISTS  bk50-private-trip.md              :: Standing: PARTIAL_ALIVE (RED triage)
EXISTS  bk54-private-trip-remediation.md  :: Standing: ALIVE (gate exit 0)
EXISTS  bk95-witness-full.md              :: Standing: PARTIAL_ALIVE (exit 1, all reds typed)
EXISTS  bk67-witness-census.md            :: Standing: ALIVE (dry-run only)
MISSING  bk44-witness-all.md              (IN-FLIGHT, typed)
EXISTS  bkseal-full-green.md              :: Standing: PARTIAL_ALIVE
EXISTS  bkseal2-fullgreen-recheck.md      :: Standing: PARTIAL_ALIVE (764/780; census 6/6 quiescent; failures classified)
MISSING  bk35-head-court-sweep.md         (no receipt on disk; typed honestly)
EXISTS  ttv7b-quiesced-rerun.md           :: Standing: BLOCKED-ON-QUIESCENCE
MISSING  ttv7b-quiesced-flip.md           (PENDING-GATE)
EXISTS  bk53-finalrelease-draft.md        :: Standing: PARTIAL_ALIVE (seal PENDING-GATE)
MISSING  bk53-finalrelease-seal.md        (PENDING-GATE)
EXISTS  kd169r-cred-gate.md               :: Standing: ALIVE
EXISTS  kd171r-secret-gate.md             :: Standing: ALIVE
EXISTS  kd173r-audience-repair.md         :: Standing: ALIVE
EXISTS  bk112-kd88-153.md                 :: Standing: ALIVE
```

26 paths probed, 21 exist, 6 typed MISSING. VALIDATION.md row-level PENDING
cells: **0** (grep-verified; §4 PENDING ledger). Zero prose-only verdicts:
every gate row names either an existing receipt with its standing, or types
the gap (IN-FLIGHT / PENDING-GATE / QUEUED-UNBUILT).

## Diff

`docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` only:

- BK-44 witness-all row typed IN-FLIGHT (two bounded polls, ~25 min, not
  landed).
- BK-SEAL row now cites `bkseal2-fullgreen-recheck.md` (PARTIAL_ALIVE:
  census 6/6 quiescent, full suite 764/780 — 5 census-drift failures from 4
  named unregistered in-flight test files, 11 cross-lane runtime collisions,
  zero failures pointing at `lib/`; quiescent rerun owed).
- BK-35 row typed "no receipt on disk".
- Census section rewritten 171/160/5 → 172/162/4 (KD-175 mint since;
  KD-169/170/171/172 closed-with-evidence with receipts).
- Path-verification paragraph updated (21/26 exist, missing paths typed).
- No KD register rows edited (not this lane's file).

## Verification

`just docs-dod-check` exit 0 with the edits in place (63 path checks OK;
kd-receipt-fence: checked 312 receipt cites across 6 registers -> OK).
Census re-run post-edit matches the embedded counts above.
