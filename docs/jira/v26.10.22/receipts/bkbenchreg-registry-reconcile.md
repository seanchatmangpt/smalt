# BK-BENCHREG — bench REGISTRY reconciliation with SUSPECT-PERMANENT typing

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-BENCHREG

## What was done

Reconciled `scripts/bench/REGISTRY.md` with the SUSPECT-PERMANENT typing of the
5 heavy bench rows (typed by BK-REWIT wave 1,
`docs/jira/v26.10.22/receipts/bkrewit-wave1.md`). No bench lanes were run; no
refresh dates invented — last-witnessed dates are the original receipts' own
run dates.

### Per-row reconciliation table

| lane | receipt | last-witnessed run | standing | registry action |
|---|---|---|---|---|
| b2 (blob SDK, TS) | v26.10.14 `bench-02-blob-ts.md` | 2026-10-15 | SUSPECT-PERMANENT-with-owner (NO-CONTEXT) | added SUSPECT row w/ quiesced-machine prescription, block 39020..39025 |
| b3 (cosmos SDK, TS) | `bench-03-cosmos-ts.md` | 2026-10-16T02:38Z | SUSPECT (receipt standing ALIVE; index types it SUSPECT NO-CONTEXT — divergence noted, not silently resolved) | added SUSPECT row, block 39030..39035 |
| b4 (messaging SDK, TS) | `bench-04-messaging-ts.md` | 2026-10-15/16 | SUSPECT-PERMANENT-with-owner (NO-CONTEXT) | added SUSPECT row, block 39040..39045 |
| b5 (python mirror) | `bench-05-python-mirror.md` | 2026-10-15 | SUSPECT-PERMANENT-with-owner (NO-CONTEXT) | added SUSPECT row, block 39050..39055 |
| c8 (chaos cross overlay) | `c8-chaos-cross.md` | 2026-10-16 04:07-04:12 PDT | SUSPECT-PERMANENT-with-owner (NO-CONTEXT) | added SUSPECT row, block 39280..39285 |

### Citation/tmp-path sweep (real results, 2026-10-22)

```
$ ls tmp/bench/affidavit-seal.jsonl tmp/bench/c11-tf-loop.jsonl
ls: tmp/bench/affidavit-seal.jsonl: No such file or directory
ls: tmp/bench/c11-tf-loop.jsonl: No such file or directory
$ ls docs/jira/v26.10.16/bench/affidavit-seal.jsonl docs/jira/v26.10.16/bench/c11-tf-loop.jsonl tmp/nreg-n7-witness.jsonl
docs/jira/v26.10.16/bench/affidavit-seal.jsonl
docs/jira/v26.10.16/bench/c11-tf-loop.jsonl
tmp/nreg-n7-witness.jsonl
```

- c10 + c11 registry rows pointed at tmp/bench/ copies that no longer exist;
  rows updated to name the canonical docs/jira/v26.10.16/bench/ mirrors.
- All receipt paths cited in REGISTRY.md (bknreg, bknenv, bkbld, bkn2b,
  bkrewit now added) verified on disk.
- Result files verified present: v26.10.14 bench dir b2/b3/b4(+run2)/b5/c8
  jsonl all on disk.
- n7 witness jsonl (tmp/nreg-n7-witness.jsonl) still on disk — no edit.

## Net diff

REGISTRY.md only: c10/c11 canonical-path fix-ups + new section
"SUSPECT-PERMANENT reconciliation (v26.10.22, lane BK-BENCHREG)" with the
per-row table above. Lane registrations otherwise unchanged; no standing
upgraded, no date faked.

## Falsifier

1. A PASS/refreshed date for any of the 5 rows without a new embedded-output
   bench receipt postdating this one refutes the reconciliation.
2. `ls tmp/bench/affidavit-seal.jsonl` succeeding again without the registry
   row being re-pointed would indicate churn, not drift.
3. If a bench-runner lane re-runs a lane on a quiesced machine, the flip goes
   through a new receipt + this table — never by regex alone.
