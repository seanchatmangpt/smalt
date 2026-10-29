# Receipt: KD-KLV — KD-180 row mint + records.ex KD-COVERS token + KD-174 dual-stamp amendment

- **Lane**: KD-KLV (`/Users/sac/smalt`, canonical checkout)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Mode**: registrar lane; edits = KD register (canonical + window) + comment-only token in `lib/smalt/messaging/kafka/records.ex` + this receipt

## What landed

Typed findings BK-KFKV-1 and BK-KFKV-2 (receipt
`docs/jira/v26.10.22/receipts/bkkfkv-replay-verify.md`) are discharged:

1. **KD-180 minted** (canonical table `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
   — ground truth — + window row in `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`;
   window pointer updated Mint-from KD-180 → KD-181): the Kafka legacy-face
   recordsCount divergence — `admit_one` called `Records.count(raw)` before
   dispatching on magic, so legacy magic-0/1 frames >= 61B read payload bytes
   at 57..60 as the count (single 60-byte produce jumped hwm 0 → 0x42424242;
   journal replay restored corrupted counts; legacy parse returned 1 record so
   F3 never fired). Status at mint: **CLOSED-WITH-EVIDENCE**, registrar
   close-typing per the KD-175/KD-176 mint-then-close precedent — the fix
   (BK-KFKC magic-first `count/1` dispatch + legacy F3 cross-check) landed
   before the row was minted and the witness receipts
   (`bkkfkskep-kafka-audit.md` defect-on-HEAD + `bkkfkv-replay-verify.md`
   post-fix replay/adversarial legs, ALIVE, Context: solo) carry the evidence.
   Note: BK-KFKV's "candidate KD-176" pointer is superseded — KD-176 was minted
   by the BK-MAAP6 lane (MAA nonce bounds); the legacy-count row is KD-180.
2. **`# KD-COVERS: KD-180` token added** to the BK-KFKC repair-site comment
   block in `lib/smalt/messaging/kafka/records.ex` (comment-only, inside the
   existing BK-KFKC block; no code change).
3. **KD-174 dual-stamp amendment (BK-KFKV-1)** — one clause added to the truth
   cell in BOTH the canonical KD-174 row and the window KD-174 bullet: the
   broker stamps the base offset into BOTH the served wrapper offset field AND
   the batch's inner baseOffset field (batch bytes 0..7, CRC-neutral) — a
   no-op at base 0, so exact-compare witnesses at base > 0 must stamp both.

## Gates (fresh runs, actual output)

```
$ python3 scripts/kd_flip.py            # read-only, no --apply
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused

$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 737 receipt cites across 6 registers + 2 pattern
docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> OK

$ just docs-dod-check
kd-receipt-fence: ... -> OK     (exit 0; every receipt path named in docs exists)
```

Pre- and post-mint FLIP-ELIGIBLE 0 — no spurious eligibility minted; KD-168
DO-NOT-FLIP hold intact (PENDING-WITNESS row is the registrar hold, refused).

## Honest notes

- `records.ex` mtime was bumped to 07:02 by the coordinator checkpoint
  landing BK-KFKC's in-flight snapshot AFTER the KFKV receipt was written
  (07:01); this lane's comment-only edit is on top (mtime 07:03). The KD-180
  close is evidence-gated on the KFKV/KFKSKEP receipts' witnessed legs (tree
  state), not on mtime ordering; no tool flip was taken, so the mtime gate
  was never exercised for KD-180.
- A PreToolUse edit warning flagged `records.ex` as modified-on-disk mid-edit
  (concurrent-window checkpoint churn); the token region was re-read from disk
  post-edit and verified byte-correct (grep line 100).
- The window register's KD-180 bullet notes BK-KFKC's own receipt
  (`bkkfkc-legacy-count.md`) is still not on disk; this lane's close stands on
  the KFKV verify receipt + tree state, per the KFKV receipt's own typing.

## Falsifiers

- Row mint is honest iff the defect existed and is repaired: KFKSKEP witnessed
  0x42424242 on HEAD pre-fix; KFKV witnessed hwm one-per-frame + lying-count
  refusals post-fix — both receipts on disk, evidence chain complete.
- kd_flip must stay FLIP-ELIGIBLE 0 after mint — holds (fresh run above).

## Standing

ALIVE: register rows + token + receipt landed, all three gates green with
embedded output. No lib/ code change authored by this lane (comment-only
token).

## Disclosure (post-commit correction, fix-forward)

Commit 19390348's records.ex diff is NOT comment-only: BK-KFKC's repair code
(magic-first `count/1` dispatch + legacy F3 cross-check in `parse_records/1`,
the content verified by BK-KFKV) was present in the working tree but NOT yet
committed when this lane staged `records.ex` — the commit carried the repair
plus the KD-180 token. The lane authored only the token line; the repair code
is BK-KFKC's, and its behavior is witnessed by `bkkfkv-replay-verify.md` and
the 18-passing kafka suites. The commit message's "(comment-only, no code
change)" wording for records.ex is corrected by this disclosure, per the
compile-freeze / disclosure law (lane-KLV staged a file carrying another
lane's landed-but-uncommitted work; attributed here explicitly).
