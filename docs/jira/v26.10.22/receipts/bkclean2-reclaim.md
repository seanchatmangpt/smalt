# BK-CLEAN2 — lane build-root reclaim

**Standing:** PASS
Context: solo
Date: 2026-10-22

## Census (before)

`ls -d _build-* | wc -l` → 20; `du -ck _build-* | tail -1` → 9,664,324 KB (~9.2 GiB).
Top: kd173r 728M, laneW2C 727M, bkcells 726M, eplaw 721M, certa 713M, bk122rr 713M,
bkkwt 654M, bk7c 366M, bkskipport 363M, expl6r1 357M, witness/kfkx4/kd166f/bkseal/
bkisol/bkcens/bkamqpf 350M each, bk70rr 326M, expl8 12M, expl9 1.8M.

Cross-checked against `docs/jira/v26.10.22/_LANES.md` (BK-8 reconcile) and
`receipts/INDEX.md` (142 receipts).

## Reclaimed (deleted)

Landed lanes (receipt on disk, not in live list):

- `_build-certa` (713M) — BK-CERTA landed, `receipts/bkcerta-blast-radius.md`, commit b6f9c09c
- `_build-bkskipport` (363M) — BK-SKIPPORT landed, `receipts/bkskipport-fetch-ports.md`, commit b6f9c09c
- `_build-expl6r1` (357M) — EXPL-6 round 1, `receipts/expl6r1-journal-repairs.md`
- `_build-kd166f` (350M) — KD-166F witness, `receipts/kd166-fix-witness.md`
- `_build-bkamqpf` (350M) — `receipts/bkamqpf-f2a-boundary.md`

Plus `/tmp/smalt-bk129r` (1.0 GiB) — BK-129r scratch, lane not in live list.

## After

`ls -d _build-* | wc -l` → 15; `du -ck _build-* | tail -1` → 7,490,772 KB (~7.1 GiB).
Build roots reclaimed: 2,173,552 KB ≈ **2.07 GiB**; total incl. /tmp ≈ **3.1 GiB**.

## Kept (live lanes)

kd173r, laneW2C, bkcells, eplaw, bk122rr, bkkwt, bk7c, witness, bkseal, bkisol,
bkcens, bk70rr, expl8, expl9 — all named in the live list.

## Kept-pending (unsure)

- `_build-kfkx4` (350M) — owner not in either list; retained per when-unsure-keep.
