# BK-10c — FINAL-RELEASE KD census refresh (BK-10b F1)

**Standing**: PASS
**Context**: solo
**Date**: 2026-10-22
**Lane**: BK-10c (doc edit + this receipt only)

## Task

Close BK-10b finding F1: `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md`
census section carried stale totals (160 rows / 152 CLOSED, anchored to
bk75 2026-10-21). Re-census mechanically on the current register.

## Embedded census (real output)

```
$ awk -F'|' '/^\| KD-/{s=""; for(i=2;i<=NF;i++) if($i!~/^ *$/) s=$i; \
    gsub(/^ +| +$/,"",s); print s}' \
  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md > /tmp/kd10c-status.txt
$ wc -l < /tmp/kd10c-status.txt
166
$ grep -c '^CLOSED' /tmp/kd10c-status.txt
158
$ grep -c '^OPEN' /tmp/kd10c-status.txt
2
$ grep -cE '^(OPEN|CLOSED|PINION|UNSUPPORTED|ENVIRONMENT)' /tmp/kd10c-status.txt
166
$ grep -oE '^\| KD-[0-9]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort | uniq -d | wc -l
0
```

Breakdown of 158 CLOSED: incl. 5 case-variant `CLOSED-with-receipt` rows
(KD-18/19/20/21/49) and the formerly-OPEN KD-88 + KD-153, now
CLOSED-WITH-EVIDENCE (witness `docs/jira/v26.10.22/receipts/bk112-kd88-153.md`).
Non-CLOSED typed states (8): 2 OPEN-TYPED-DISPOSITION (KD-166 webpubsub
subprotocol, KD-168 attestation environment-gated), 4 PINION/PINION-WITNESSED
(KD-05, KD-101, KD-159, KD-160), 1 ENVIRONMENT-PINION (KD-162), 1
UNSUPPORTED-BY-COST (KD-90). 158+2+4+1+1 = 166, no skew; 0 duplicate ids.
Convention matches `docs/jira/v26.10.22/receipts/bk11-kd-legacy-triage.md`
(identical totals at its run).

## Diff

`docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` — census section
("Open residuals") rewritten: 160→166 total, 152→158 CLOSED, OPEN list
KD-88/KD-153 → KD-166/KD-168 (with bk112 close note), anchor updated to
2026-10-22, fresh-truth pointer now names this receipt + bk11. No other
sections touched. Path-verification spot-check of cited receipts
(ttv7b-quiesced-rerun, bk53-finalrelease-draft, SYNC-CHARTER,
bk50-private-trip, bk48-pinion-witness, bk112, bk11): all exist on disk.

## Verification

Post-edit grep of the doc: no remaining `160`/`152`/stale bk75 anchor;
the only KD-88/KD-153 mentions are the intentional former-OPEN note.
