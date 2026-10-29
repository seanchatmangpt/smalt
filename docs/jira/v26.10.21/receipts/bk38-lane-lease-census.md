# BK38 — Lane-lease census (report-only)

**Standing:** **ALIVE** (census executed, all numbers re-read from disk at 2026-10-21 20:08 PDT)
- Context: solo
- Date: 2026-10-21 · Lane: BK38 (census lane, read-only except this receipt) · Subject: /Users/sac/smalt @ main (12ba2c2+)

## Method

`du -sh _build-* _bench-* popcorn_demo/_build-*` → owner/status classification
from (a) receipt existence in `docs/jira/v26.10.21/receipts/`, (b) commit-log
landings (`git log --since=19:00`), (c) `tmp/` scratch-log mtimes, (d) live
beam cwd sweep (`pgrep beam.smp` + `lsof`), (e) the v7/v7.1 fold in
`_LANES.md`. A root is **landed** only when its lane's receipt is on disk AND
its landing commit is in the log; anything else keeps its lease.

## Disk snapshot

    $ df -h /
    Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on
    /dev/disk3s1s1   926Gi    11Gi    78Gi    13%    453k  816M    0%   /   (78 GiB available)

## Root-level lane build roots (29 roots, 17.0 GiB)

| Root | Size | Owner lane | Status | Evidence |
|---|---|---|---|---|
| _build-bk1 | 350M | BK-1 (AMQP10 court closure) | **LANDED** (reclaim) | `receipts/amqp10-court-closure.md`; commit 528f05c |
| _build-bk2 | 363M | BK-2/IMPL-14 (ML-KEM flip) | **LANDED** (reclaim) | `receipts/imp14-mlkem-flip.md`; commit c8d9ba1 |
| _build-bk3 | 712M | BK-3 (JSONSAX re-verification) | **LANDED** (reclaim) | `receipts/snippet-jsonsax-stream.md`; commit c02806f |
| _build-bk4 | 350M | BK-4 (FONDRUNNER court) | **LANDED** (reclaim) | `receipts/fondrunner-court.md`; commit 5a993a5 |
| _build-bk5 | 362M | BK-5 (POWL bench re-run) | **LANDED** (reclaim) | `receipts/powlbench-fresh-rerun.md`; commit 74c7960 |
| _build-bk6 | 713M | BK-6 (partial closures + KD-157 H2 witness) | **LANDED** (reclaim) | `receipts/bk6-validation-partial-closures.md`, `receipts/bk6-kd157-h2-postrestart-witness.md`; commit 1abdee3 |
| _build-bk11 | 362M | BK-11 (KD legacy-row triage) | **LANDED** (reclaim) | `receipts/bk11-kd-legacy-triage.md`; commit dfc42ea |
| _build-bk17 | 350M | BK-17 (powl2 graph-compat witness) | **LANDED** (reclaim) | `receipts/bk17-graph-compat-witness.md`; commit 71d81b0 |
| _build-bk18 | 362M | BK-18 (KD-142 blob error contract) | **LANDED** (reclaim) | `receipts/bk18-blob-error-contract.md`; commit dadf1e0 19:43 |
| _build-ja5 | 712M | JA-5 (fail-fast court) | **LANDED** (reclaim) | `receipts/ja5-fail-fast-court.md`; commit 2d4bb9d |
| _build-jar3 | 712M | JA-R3 (JA-16 defect fixes) | **LANDED** (reclaim) | `receipts/ja-r3-ja16-defect-fixes.md`; commit 08acebf 19:41 |
| _build-ttv7 | 362M | TTV-7 (warmed-p99 standard) | **LANDED** (reclaim) | `receipts/ttv7-warmed-p99-standard.md`; commit 44047b4 |
| _build-bk7 | 350M | BK-7 | LIVE (lease held) | tmp/bk7-final.log mtime 20:08, recompile series |
| _build-bk14 | 705M | BK-14 | IN-FLIGHT/UNWITNESSED (lease held) | no receipt; mtime 19:38; not named landed in any fold |
| _build-bk19 | 677M | BK-19 | IN-FLIGHT/UNWITNESSED (lease held) | no receipt; mtime 20:00 |
| _build-bk21 | 674M | BK-21 | LIVE (lease held) | in-flight snapshot commit 08acebf 19:41; tmp/bk21/boot.log 19:59 |
| _build-bk23 | 717M | BK-23 | LIVE (lease held) | in-flight snapshot commit dadf1e0 19:43; mtime 19:58 |
| _build-bk24 | 647M | BK-24 | LIVE (lease held) | in-flight snapshot commit dadf1e0 19:43; mtime 20:00 |
| _build-bk25 | 362M | BK-25 | LIVE (lease held) | in-flight snapshot commit dadf1e0 19:43 |
| _build-bk26 | 362M | BK-26 | LIVE (same wave as 23–26) | in-flight snapshot commit dadf1e0 19:43 |
| _build-bk27 | 353M | BK-27 | IN-FLIGHT/UNWITNESSED (lease held) | no receipt; mtime 19:55 |
| _build-bk35 | 338M | BK-35 | IN-FLIGHT/UNWITNESSED (lease held) | no receipt; mtime 19:58 |
| _build-ja9 | 350M | JA-9 (bench scaling) | LIVE (lease held) | `scripts/bench/ja9_scaling.exs` modified in tree; tmp/bench-ja9-run11.log 20:06 |
| _build-ja10 | 350M | JA-10 (transparency court) | LIVE (lease held) | `test/integration/ja10_transparency_court.exs` modified in tree |
| _build-ja13 | 362M | JA-13 (supervisor intensity) | LIVE (lease held) | UNWITNESSED live beam at v7 census; mtime 19:02 |
| _build-ja15 | 1.3G | JA-15 (probe/court) | LIVE (lease held) | tmp/ja15-court1.log mtime 20:08 |
| _build-lane-r1 | 712M | lane-r1 (JA-R1 family) | IN-FLIGHT/UNWITNESSED (lease held) | `receipts/ja-r1-silent-violation-fixes.md` landed 19:48 — root kept conservatively (recent mtime 19:35; wrap lane may reclaim after confirmation) |
| _build-lane-r2 | 712M | lane-r2 (JA-R2 family) | IN-FLIGHT (lease held) | named LIVE at v7; `receipts/ja-r2-apim-atom-bridge-fixes.md` landed 19:40 — same conservative hold |
| _build-ttv4 | 362M | TTV-4 (journal boot-replay) | LIVE (lease held) | `test/integration/ttv4_journal_boot_replay_court.exs` modified in tree; DIRECTIVES ledger row TTV-4 QUEUED→in flight |

## _bench-* harness roots (5, 124K total)

cosmos 12K · escript 60K · json 12K · powl 24K · rcpt 16K. Bench-lane harness
dirs for the landed bench family (bench3/5/6/7/8 receipts on disk); trivial
size — not worth a deletion transition, listed for completeness.

## popcorn_demo/_build-* (19 roots, ~60 MiB total)

Historical sub-lane roots from earlier sub-waves (apex1/3/4, bk23, ckpt,
cost1, e1..e6, final, kv404/kvleg/kvtf, otp29p, reconf, tracebug, x3,
z1/z2/z3/z5) — earlier-wave lanes whose receipts are in the landed set
(impl9-otp29-pin, bk9-popcorn-live-leg, etc.). Landed/historical, ~60 MiB
reclaim-eligible as a secondary bucket at wrap discretion (low value, small).

## Reclaim list for the wrap lane (landed roots only — nothing deleted by this lane)

| Root | Size |
|---|---|
| _build-bk1 | 350M |
| _build-bk2 | 363M |
| _build-bk3 | 712M |
| _build-bk4 | 350M |
| _build-bk5 | 362M |
| _build-bk6 | 713M |
| _build-bk11 | 362M |
| _build-bk17 | 350M |
| _build-bk18 | 362M |
| _build-ja5 | 712M |
| _build-jar3 | 712M |
| _build-ttv7 | 362M |
| popcorn_demo/_build-* (19 roots) | ~60M (secondary bucket) |
| **Total** | **~5.6 GiB (primary 12 roots) + ~60 MiB popcorn (secondary)** |

## Non-vacuity / falsifier

Falsifier: any root on the reclaim list whose lane receipt is missing from
`receipts/` or whose landing commit is not in `git log`. Checked per-row; all
12 primary rows carry both a receipt path and a commit anchor. Nothing was
deleted by this lane (report-only mandate held — no `_build-*` writes).
