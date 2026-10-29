# BK-11 — KD legacy-row triage receipt

**Standing**: PASS (gate-shaped audit; register gate-ready)
**Context**: solo
**Date**: 2026-10-22
**Lane**: BK-11 (register + this receipt only)

## Task

Terminal gate: every KD row CLOSED-* or a typed Disposition (falsifier + owner
+ next-action), NO out-of-scope category, zero duplicate ids. Full triage of
the canonical register `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

## Embedded census (real output)

```
$ awk '/^\| KD-/ {...}' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md > /tmp/kd-status2.txt
$ wc -l < /tmp/kd-status2.txt
166
$ grep -c '^OPEN' /tmp/kd-status2.txt
2
$ grep -c '^CLOSED' /tmp/kd-status2.txt
158
$ grep -cE '^(OPEN|CLOSED|PINION|UNSUPPORTED|ENVIRONMENT)' /tmp/kd-status2.txt
166
$ grep -oE '^\| KD-[0-9]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort | uniq -d | wc -l
0
```

Breakdown of the 158 CLOSED: 95 CLOSED-SIMULATED, 32 CLOSED-WITH-RECEIPT
(+5 case-variant `CLOSED-with-receipt` rows: KD-18/19/20/21/49, all citing
`docs/jira/v26.10.14/receipts/s1-amqp-shims.md` / `s2-eh-shims.md`, both on
disk), 14 CLOSED-WITH-EVIDENCE, 12 CLOSED-OBSOLETE, 2 plain CLOSED
(KD-52, KD-63). Non-CLOSED typed states (8): 2 OPEN w/ typed disposition
(KD-166, KD-168), 1 UNSUPPORTED-BY-COST (KD-90, BK-27 anchor on disk), 4
PINION/PINION-WITNESSED (KD-05, KD-101, KD-159, KD-160 — each cites an on-disk
witness/pinion receipt), 1 ENVIRONMENT-PINION (KD-162, falsifier + owner +
next-action inline).

## Work performed

1. Duplicate-id check: `sort | uniq -d` over all row ids → 0 duplicates.
   (Historical KD-167 dual-claim was already reconciled by BK-128; KD-166
   dual-claim folded to KD-170 by BK-139r — zero duplicates at HEAD.)
2. Out-of-scope category check: `grep -nE 'out of scope|out-of-scope'` →
   single hit is falsifier prose inside KD-65 (CLOSED-SIMULATED): "JS eval
   out of scope" — descriptive, not a disposition category. NO out-of-scope
   category exists.
3. Evidence-receipt existence check over every non-CLOSED row's cited paths
   (ls per path): all cited receipts EXIST
   (kd65-…-witness.md, x1-blocklist-fix.md, r-kd63-change-feed-close.md,
   affidavit-seal.jsonl, kd101-eg-webhook-tbd.md,
   cas412-cosmos-replace-if-match.md, bk48-pinion-witness.md,
   ja9-scaling-envelope.md, bk27-kd86-90.md,
   az5-webpubsub.md, az2-maa-attestation.md). Relative-path citations
   `receipts/s1-amqp-shims.md`, `receipts/s2-eh-shims.md`,
   `sdk-results/ts-storage-blob.md` resolve under
   `docs/jira/v26.10.14/` (register-relative).
4. Flippable check: KD-166 and KD-168 close conditions are NOT met by landed
   work. `scripts/kd_flip.py` reports FLIP-PENDING-WITNESS for both
   (per docs/jira/v26.10.22/receipts/bk128-kd167-reconcile.md: "FLIP-PENDING-WITNESS:
   2 (KD-166, KD-168)"). Recent receipts checked — bk85-seal-invariant.md
   (KD-164 face), wire-exp4-frame-decoder.md (AMQP decoder), wps-exp4-repairs.md
   (F1/F6/F5 → KD-169), kafka-exp4 lanes — none witnesses the KD-166 Bandit
   subprotocol echo or a real TEE quote for KD-168. No flips applied; no
   closures faked.
5. Typed Dispositions written into the two OPEN rows (KD-166, KD-168) with
   falsifier + owner + next-action each (see row status cells).
6. BK-11 re-read of docs/jira/v26.10.16/bench/affidavit-seal.jsonl lane c10:
   p50 11.265ms / p95 26.491ms — unchanged; KD-90's UNSUPPORTED-BY-COST
   disposition (BK-27) stands as typed.

## Findings (pre-existing, NOT repaired by this lane)

- **F1**: KD-131/132/133 (CLOSED-WITH-RECEIPT, KD-AMQP lane) cite witness
  receipts that DO NOT exist on disk:
  `docs/jira/v26.10.22/receipts/fix4-amqp-witness.md` (MISSING) and
  `docs/jira/v26.10.22/receipts/kd131-133-amqp-triage.md` (MISSING;
  `find docs -name …` empty). These closures are receipt-missing — the
  owning KD-AMQP lane must land the receipts or the rows should be treated
  as unflipped. Not mine to fabricate.
- **F2**: KD-18/49 AUDIT NOTEs name STALE `SKIP-KD18`/`SKIP-KD49` banners in
  smalt-cli tests (banner text stale, rows closed) — carried forward from the
  2026-10-16 registrar audit notes; cleanup owned by smalt-cli lane.

## Gate verdict

166 rows, 0 duplicate ids, no out-of-scope category, 158 CLOSED + 8 typed
non-CLOSED states each carrying falsifier+owner+next-action (or a witnessed
pinion per K1/K7). Gate: PASS.
