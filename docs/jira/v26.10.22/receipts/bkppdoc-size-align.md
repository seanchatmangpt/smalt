# BK-PPDOC — receipt-size prose alignment across doc set: 2 stale PRD cells fixed, rest verified sync-token — PASS

**Standing**: PASS
Context: solo
Date: 2026-10-22
Lane: BK-PPDOC
Anchor: receipts/bkrsize-receipt-truth.md (D1 resolution: sync token = 320 B / 640 hex, layout-pinned; pplan seal term = 48 words / 384 B post-GAP-6a, was 40 pre-GAP-6a)

## Embedded commands + output

```
$ grep -rnE '320 ?B|320-byte|40.word|40 word|384 ?B|48.word' docs/jira/v26.10.22/*.md docs/*.md | grep -v receipts/
ARCH-SYNC-MEMO.md:27  48-word (384 B) … pplan seal term, post-GAP-6a … sync wire receipt stays fixed 320 B   [already updated by BK-RSIZE — correct]
PRD.md:21             provenance by construction (40-word O(1) Merkle receipts)                              [STALE — FIXED]
PRD.md:55             NFR-EVI-001 | 40-word O(1) receipt | pb4: 40 words = 320B, O(1) at n=10..10^5          [STALE — FIXED]
pillars-cross-industry.md:28  sealed root + 320-byte (640-hex-char) …                                        [sync-token surface — correct, keep]
SYNC-CHARTER.md:32    (4) 320-byte Merkle receipt returned …                                                 [sync-token surface — correct, keep]
W3C-FORMALIZATION.md:12 320-byte binary receipt … proprietary-framed … binary receipt stays the wire format  [sync-token surface — correct, keep]
SYNC-RECEIPT-CHAIN.md:95-101  320 B layout-pinned token … term is now 48 heap words (384 B) …                [already updated by BK-RSIZE — correct]

$ # re-census after edits: same grep, PRD lines now read
PRD.md:21  construction (O(1) Merkle receipts: fixed 320 B sync token; 48-word/384 B pplan
PRD.md:56  NFR-EVI-001 | O(1) receipt (two surfaces) | sync token: fixed 320 B at every n (BK-92
           cross-mint, layout-pinned); pplan seal term: 48 words = 384 B at n=10..10^5
           post-GAP-6a (PB4-R re-run; was 40 words pre-GAP-6a) — bkrsize-receipt-truth
```

## Classification

- **Sync-token claims (correct, kept)**: pillars-cross-industry.md P5, SYNC-CHARTER.md
  step (4), W3C-FORMALIZATION.md row 2 — all three name the 320-byte/640-hex wire
  receipt, which is unchanged and layout-pinned.
- **Stale pplan-seal claims (fixed)**: PRD.md §1 prose (40-word → dual-figure) and
  NFR-EVI-001 row (40 words = 320 B conflation → two-surface anchor with bkrsize
  citation).
- **Ambiguous**: none found — every cell names its surface after the BK-RSIZE §3 /
  ARCH-SYNC-MEMO edits; the two remaining PRD cells were the only conflations.
- **VALIDATION.md**: zero receipt-size cells (grep census returned no 320 B /
  40-word / 384 B / 48-word hits in that file) — nothing to change.

## Whitepaper

`lithography.tex` NOT touched, nothing appended. Remaining doc set is now consistent
with bkrsize-receipt-truth, so the operator's whitepaper edit is mechanical: 40→48
words, 320→384 B for the pplan seal figure, sync-token 320 B figures left as-is, and
cite `receipts/pb4r-identity-court.md` for the seal ladder (prescription already in
the bkwp2 drift table).

## Falsifier status

Survived: post-edit re-census shows every remaining size claim names the sync-token
surface (unchanged, correct) or the two-surface truth with anchors. Killed:
"docs still carry the stale pre-GAP-6a 40-word figure as the only claim" — only the
whitepaper (operator-owned) can still do so.
