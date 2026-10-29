# KD-SYNC — pointer sync + fresh census (KD-166 flip / KD-167, KD-172, KD-173 mint drift)

**Standing**: PASS
**Context**: solo
**Date**: 2026-10-22
**Lane**: KD-SYNC (pointer + census prose + this receipt only)

## Task

Rapid registrar activity this window (KD-166 flipped CLOSED-SIMULATED,
KD-167 CLOSED-WITH-EVIDENCE appended, KD-172 + KD-173 minted) left the
v26.10.22 pointer line stale ("Mint from KD-173" while KD-173 now exists)
and the FINAL-RELEASE census prose anchored to bk10c (166/158). Sync both
to fresh truth, read fresh from the register — no row content touched.

## Embedded census (real output, bk10c/bk11 awk convention)

```
$ awk -F'|' '/^\| KD-/{s=""; for(i=2;i<=NF;i++) if($i!~/^ *$/) s=$i; \
    gsub(/^ +| +$/,"",s); print s}' \
  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md > /tmp/kdsync-status.txt
$ wc -l < /tmp/kdsync-status.txt
     167
$ grep -c '^CLOSED' /tmp/kdsync-status.txt
159
$ grep -c '^OPEN' /tmp/kdsync-status.txt
2
$ grep -oE '^\| KD-[0-9]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort | uniq -d | wc -l
       0
$ grep -oE '^\| KD-[0-9]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort -V | tail -1
| KD-172
$ grep -c '^- KD-' docs/jira/v26.10.22/KNOWN_DIVERGENCES.md
5
```

Canonical table: **167 rows, 159 CLOSED, 0 duplicates, highest table id
KD-172**; non-CLOSED (8) = KD-05/KD-90/KD-101/KD-159/KD-160/KD-162
(4 PINION + 1 PINION-WITNESSED pair + 1 ENVIRONMENT-PINION + 1
UNSUPPORTED-BY-COST), KD-168 + KD-172 (2 OPEN typed). Window doc adds
5 rows (KD-169..KD-173; KD-170 CLOSED-WITH-EVIDENCE, rest
OPEN-registered), **highest minted id overall = KD-173**. Delta vs
bk10c-at-its-run (166/158): KD-166 OPEN→CLOSED-SIMULATED, KD-167 appended
CLOSED-WITH-EVIDENCE. 159+2+4+1+1 = 167, no skew.

## Diff

1. `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` — pointer line only:
   "Mint from KD-173 (highest minted id is KD-172)" → "Mint from KD-174
   (highest minted id is KD-173)". No row content touched.
2. `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` — census section
   ("Open residuals"): 166→167 total, 158→159 CLOSED, OPEN list
   KD-166+KD-168 → KD-168+KD-172 (with KD-166 CLOSED-SIMULATED note and
   KD-169..173 window-rows note), fresh-truth anchor updated from bk10c to
   this receipt. No other sections touched.

## Cross-checks

- Canonical v26.10.14 register carries NO "Mint from" pointer line
  (grep-verified) — nothing to fix there; the pointer exists only in the
  v26.10.22 doc. No row-level conflict with the in-flight KD-173R lane:
  zero KD-174+ ids minted anywhere (the only `KD-17[4-9]` hit is this
  pointer's own mint-from token).
- kd_flip read-only (exit 0): FLIP-ELIGIBLE 1 (KD-168, witness bk10c
  census — registrar territory, NOT flipped by this lane);
  FLIP-PENDING-WITNESS 1 (KD-172, no post-shim receipt newer than shim
  mtime 2026-10-22T04:42:09).
- `just docs-dod-check`: exit 0, all cited receipt paths exist.

## Gates (real output)

```
$ python3 scripts/kd_flip.py        # read-only
FLIP-ELIGIBLE: 1
  KD-168: witness docs/jira/v26.10.22/receipts/bk10c-census-refresh.md
FLIP-PENDING-WITNESS: 1
  KD-172: no post-shim receipt newer than shim mtime (2026-10-22T04:42:09)
EXIT=0
$ just docs-dod-check
[...OK lines for every cited doc path...]
EXIT=0
```
