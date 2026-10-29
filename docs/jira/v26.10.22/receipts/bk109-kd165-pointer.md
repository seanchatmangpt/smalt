# BK-109 — KD-165 pointer-doc bump receipt

**Standing:** **PASS** — pointer doc, canonical register, and gates all verified;
no diff required, no commit (per order).

Context: solo

## Order

BK-106 minted KD-165 (sync cumulative-receipt divergence, CLOSED-WITH-EVIDENCE).
Execute the pointer-doc bump per the BK-99 pattern:
`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` — range KD-01..KD-165, KD-165 mint
bullet (client verified only flushed parts vs server cumulative chain; fixed in
journal-sync; evidence `bk106-sync-engine-fixes.md`), next-mint KD-166. Verify
`python3 scripts/kd_flip.py` read-only zero skew + `just docs-dod-check` exit 0.

## Diff

**None required — found ALIVE on inspection.** The pointer doc
`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` already carries the full bump as of
this session's read (2026-10-21):

- Header: "rows KD-01..KD-165 — 162 rows, ids non-contiguous — as of 2026-10-21";
  "Mint from KD-166 (highest minted id is KD-165)".
- KD-165 mint bullet (lines 30-35): sync engine client P12 verify vs the
  server's cumulative per-client receipt chain (`verified:false` on any flush
  after the first) — CLOSED-WITH-EVIDENCE (client-side full-ledger cumulative
  verify landed; sync-e2e-court 9/9 ×2). Evidence:
  `../v26.10.22/receipts/bk106-sync-engine-fixes.md` (BK-106; minted in the
  canonical register by BK-106).
- Closing line names KD-165 "by BK-106's sync-engine-fixes lane from the BK-83
  witness".

The canonical register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` line 345)
holds the full KD-165 row, status CLOSED-WITH-EVIDENCE, citing the same
evidence receipts (BK-83 witness + BK-106 fix receipt).

## Verification outputs

`python3 scripts/kd_flip.py` (read-only) — exit 0, zero skew:
`FLIP-ELIGIBLE: 0`, `FLIP-PENDING-WITNESS: 0` (111 KD ids from 130 files).

`just docs-dod-check` — exit 0, all 63 path checks `OK`, zero `MISS`.

## Falsifier

A pointer-doc row contradicting the canonical register (range/count/status
drift), or either gate exiting nonzero — neither observed.

## Standing boundary

Receipt documents inspection-time state only; kd_flip and docs-dod-check are
point-in-time gates. No commit made.
