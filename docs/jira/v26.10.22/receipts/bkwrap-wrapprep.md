# BK-WRAP — wrap-prep regen receipt (lane BK-WRAP)

- **Standing**: ALIVE — all four wrap-prep steps executed with embedded output; regen diff committed.
- **Context**: solo

## 1. `just receipt-index` — exit 0

Regenerated RECEIPTS.md/INDEX.md for v26.10.14 … v26.10.22 (8 milestones, 16 files written).
Generator: `scripts/receipt_index.py` via `just receipt-index`.

Generator tail (suspect-census excerpt + write lines):

```
  SUSPECT: w6p-table-storage.md (standing UNKNOWN)
  SUSPECT: wasm-memory-cdp-witness.md (standing PARTIAL_ALIVE)
  SUSPECT: bk59-warnings-recensus.md (standing PARTIAL_ALIVE)
  SUSPECT: bk81-lanes-v73.md (standing ALIVE)
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.14/receipts/INDEX.md
...
wrote /Users/sac/smalt/docs/jira/v26.10.22/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.22/receipts/INDEX.md
```

Wrote-line list (abridged): v26.10.14, v26.10.16, v26.10.17, v26.10.18, v26.10.19,
v26.10.20, v26.10.21, v26.10.22 — each RECEIPTS.md + receipts/INDEX.md.

### Recent receipts present with non-SUSPECT standing

| receipt | standing |
|---|---|
| wps-exp4-repairs.md | ALIVE |
| exp1a-worker-guard-repairs.md | ALIVE |
| exp1c-journal-sync-repairs.md | ALIVE |
| bk4-fondrunner.md | ALIVE |
| bk5-powlbench.md | PARTIAL_ALIVE |
| bk11-kd-legacy-triage.md | PASS |
| kd143-sqlfilter-close.md | ALIVE |
| bkskep-amqp10-skeptic.md | PARTIAL_ALIVE |
| bkjar-ja-repairs.md | ALIVE (standing line at HEAD per 6d322fc2) |
| bk2b-mlkem-closeout.md | ALIVE |
| kdblob-error-contract.md | ALIVE |
| boardv3 / e2er (bke2er-sync-e2e-rerun.md) | PASS |
| bk7-warnings-cleanup.md | PARTIAL_ALIVE |
| bk6-validation-closures.md | ALIVE |

**Not on disk (still in-flight lanes, correctly absent from index):**
`kafka-exp4` receipt, `exp1b` receipt. `erl3-kafka-wormhole-proposer.md` exists (ALIVE) but
is a different lane. Git status at wrap start showed `lib/smalt/messaging/kafka/*` modified
(KAFKA-EXP4 lane in flight).

## 2. `just docs-dod-check` — exit 0

All named receipt paths exist. Tail: `OK ... README.md`.

## 3. `python3 scripts/kd_flip.py` read-only sweep — exit 0

- FLIP-ELIGIBLE: 0
- **FLIP-PENDING-WITNESS: 1** — KD-168: no post-shim receipt newer than shim mtime
  (2026-10-22T04:13:40)
- WITNESS-AMBIGUOUS: 1 — KD-166: 2 candidate receipts
  (`bk11-kd-legacy-triage.md`, `bk139r-kd166-fold.md`) — needs `--witness KD-166=<path>`
  disambiguation; not mine to flip.

## 4. VALIDATION.md PENDING count (not edited)

`grep -c PENDING docs/jira/v26.10.22/VALIDATION.md` → **11** mentions.
Row-level PENDING cells per the board's own ledger (§4): **3**
(COURT-BOOT-REBIND / BK-33 UNWITNESSED; COURT-ATOM-CLAMP+CERT-OBS;
COURT-SYNC-FASTFWD/ANDON). Board standing left to BK-VCOURTS/BK-SECPEND.

## Regen diff committed

4 files, +20/−6: RECEIPTS.md ×2 (new rows: bk2b, bk6, bk7, bkjar, bkskep, expl5, kd143;
erl4r PASS→ALIVE), receipts/INDEX.md ×2 (1350→1357 total receipts, 49 SUSPECT flags
unchanged). Pre-existing working-tree modifications to `KNOWN_DIVERGENCES.md` and
`VALIDATION.md` belong to other lanes — not staged.
