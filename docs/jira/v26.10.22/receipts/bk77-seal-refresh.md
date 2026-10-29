# BK-77 — FINAL-RELEASE distribution-line refresh (BK-75 close-out)

**Standing:** **PASS**

Context: solo

Date: 2026-10-21.

## What changed

`docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` open-residual section refreshed
to match the fresh census in `docs/jira/v26.10.22/receipts/bk75-kd-final-census.md`
(PASS).

## Counts

- Before: OPEN **5** (KD-88, KD-90, KD-153, KD-159, KD-160); PINION **2**
  (KD-05, KD-101); ENVIRONMENT-PINION **1** (KD-162); sum 152+5+2+1 = 160.
- After: OPEN **2** (KD-88, KD-153); PINION / PINION-WITNESSED **4**
  (KD-05, KD-101, KD-159, KD-160); ENVIRONMENT-PINION **1** (KD-162);
  UNSUPPORTED-BY-COST **1** (KD-90); sum 152+2+4+1+1 = 160. Total unchanged at
  160 rows; KD-90/159/160 flipped after the draft census and are now typed
  Dispositions, per bk75.

## Verification

`just docs-dod-check` → exit 0 (60 paths, all OK; full output in this
session's transcript).
