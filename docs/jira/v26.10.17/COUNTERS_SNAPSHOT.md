# COUNTERS_SNAPSHOT — v26.10.17 (lane I14, executed 2026-10-17)

All figures re-derived at execution time from the commands in
`docs/jira/v26.10.17/COUNTERS.md`. Not restated from prose.

## 1. KD register totals

Command: escaped-pipe-aware python split over
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (verbatim from COUNTERS.md).

```
38 CLOSED / 55 OPEN
```

## 2. Receipt index totals

Command: `python3 scripts/receipt_index.py` (summary line; regenerates all
window INDEX.md/RECEIPTS.md files).

```
receipts=343 sdk=51 total=394 suspects=16
```

## 3. Court-x2 ledger

Command: `grep -c 'COURT_X2_RC=' tmp/court-x2-wrap-run*.log` — 32 log
files present (run2..run33); per-file count is 1 for 29 files and 0 for
run28, run29, run31. Aggregate: **29** `COURT_X2_RC=` lines on disk;
newest is `run33` (not in the ledger of record's runs 30-32 range).

Ledger of record `docs/jira/v26.10.16/WRAP_LEDGER.md` ("Court ledger
extension — runs 30-32"): **32 completed invocations, 0 two-green**
(read from disk 2026-10-17). Disk shows a run33 log with `COURT_X2_RC=1`
that postdates that ledger entry.

## 4. arm_lines_deleted seed check

Seed: **0** — no route-macro family deletion has landed under W6. Git
log over `lib/smalt/arm_gateway/router.ex` +
`lib/smalt/egress_router.ex` shows no W6 deletion commit (newest is
`d02c241` shim work, not a family deletion). Current on-disk line
counts at execution time:

```
 4445 lib/smalt/arm_gateway/router.ex
 3587 lib/smalt/egress_router.ex
 8032 total
```

Since no W6 deletion has landed, `PRE_W6_SHA` is not yet pinned and
deleted = pre − post = 0 across both families. The ~2,400-2,800 arm +
~300 egress figures in `docs/jira/v26.10.16/PROJECTION-ARCH-PLAN.md`
§1 W6 remain a planning PROJECTION, not a measurement.
