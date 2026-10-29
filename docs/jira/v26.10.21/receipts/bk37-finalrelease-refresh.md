# BK-37 — FINAL-RELEASE.md open-residual refresh (register-census alignment)

**Standing:** **ALIVE**
Context: solo · Date: 2026-10-22 · Repo: /Users/sac/smalt · Lane: BK-37
Subject: `docs/jira/v26.10.21/FINAL-RELEASE.md` (only file edited; working
tree, no commit)

## What ran

Register status-cell census over all rows of
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (last non-empty table column,
awk pass), then FINAL-RELEASE.md brought to the measured truth.

## Before → after open-row counts

- Before (FINAL-RELEASE §6 list): 10 rows named open — KD-88, KD-142,
  KD-144, KD-145, KD-146, KD-153, KD-154, KD-157, KD-159, KD-160 —
  **one wave stale** (KD-142/157/79 closed via BK-18/BK-20/BK-29,
  KD-154 via BK-36 in-flight).
- After (register census, re-read twice — a concurrent lane flipped
  KD-154 mid-census, second read taken as truth): **17 non-CLOSED rows =
  15 OPEN + 2 PINION** (KD-05, KD-101). Every row tabled with surface,
  owner/next action, falsifier. KD-79 / KD-142 / KD-154 / KD-157 moved
  out of the open list with receipt cites
  (`receipts/bk29-kd79-close.md`, `receipts/bk18-blob-error-contract.md`,
  BK-36 register cell — its receipt file not yet on disk, register cell
  named as authority,
  `receipts/bk20-kd157-witness.md` + `receipts/bk6-kd157-h2-postrestart-witness.md`).

## Diff summary (all in FINAL-RELEASE.md)

- Header: refresh date BK-37 added; §2 board pointer v6 → **v7**
  (BK-22 BOARDV3 fold); PENDING-GWS bucket row 2 → **0**
  (BK-31 + BK-32 named).
- §2: GWS wave paragraph rewritten to all-four-closed with receipts;
  post-v7 landings added — POWLBENCH fresh re-run (native p99 4/6 µs;
  settlement p99 373 µs gate breach typed as load tail; mutant leg
  29→113 µs non-vacuous; earlier 74 µs run named as where AR-PROD-05
  "within gate" rests) and TTV-7 warmed-P99 standard (falsifier FIRED:
  warm p99 197 ms under load-132; reductions stable 285.4/step).
- §3: TTV-7 p99-measurement law paragraph added; table values unchanged
  (reductions-based, unaffected by the warmed-p99 standard).
- §6: KD-157 bullet flipped to CLOSED-SIMULATED (BK-20/BK-6, post-restart
  falsifier 539–562 → 0 retries); KD-142/KD-79/KD-154 closure bullets
  added; open list replaced with the 17-row census table.
- §8: item 4 rewritten (GWS-14/15 closed; frozen-duckdb `-lduckdb` gap is
  the remaining open surface); item 6 rewritten (OBS-04 closed OBS4COURT
  + BK-6; KD-157 flip landed; TTV-7 quiesced re-run named; KD-159/160
  pinions owed).
- See Also: board pointer v5 → v7.

## Gate

```
$ just docs-dod-check; echo "EXIT=$?"   # real tail of run
OK    docs/jira/v26.10.18/FINAL.md
OK    docs/jira/v26.10.18/RECEIPTS.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
EXIT=0
```

Exit 0 (pinned-path DoD list — all paths exist; this receipt's citations
were separately `[ -e ]`-checked: bk18/bk20/bk29/bk31/bk32/bk6/powlbench/
ttv7/obs4court all present; kd13-kd75 + kd88-triage receipts verified in
their owning windows v26.10.16 / v26.10.20).

## Falsifier

Any register status cell diverging from the §6 table, or a cited receipt
path missing on disk, re-opens this refresh.

Standing of FINAL-RELEASE.md: **PARTIAL_ALIVE** (document standing
unchanged; residuals honestly enumerated in §8 + §6 table).
