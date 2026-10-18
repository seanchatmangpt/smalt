# COUNTERS_SNAPSHOT — v26.10.17 AS-OF-WRAP (re-derived 2026-10-17)

All figures re-derived at execution time from the commands in
`docs/jira/v26.10.17/COUNTERS.md`. Not restated from prose.

## 1. KD register totals

Command: escaped-pipe-aware python split over
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (verbatim from COUNTERS.md).

```
39 CLOSED / 55 OPEN
```

## 2. Receipt index totals

Command: `python3 scripts/receipt_index.py` (summary line; regenerates all
window INDEX.md/RECEIPTS.md files).

```
receipts=373 sdk=51 total=424 suspects=16
```

## 3. Court-x2 ledger

Command: `grep -c 'COURT_X2_RC=' tmp/court-x2-wrap-run*.log` — 32 log
files on disk (run3..run33 visible in the per-file tail); per-file count
is 1 except run28/run29/run31 (0); aggregate: **29** `COURT_X2_RC=`
lines on disk.

Ledger of record `docs/jira/v26.10.16/WRAP_LEDGER.md` ("Court ledger
extension — runs 30-32") says **32 completed invocations, 0 two-green**
on disk at its write time. AS-OF-WRAP (2026-10-17, after r241
court-x2 attempt 3 closed TYPED-RED): **35 completed invocations, 0
two-green** = 32 (ledger of record) + run33
(`tmp/court-x2-wrap-run33.log`, COURT_X2_RC=1, postdates the ledger)
+ attempt 3 (`tmp/court-x2-v17-wrap3.log:86`, COURT_X2_RC=1; its two
internal court runs — line 68: 4 failures incl. fence 10, line 72:
fence 10 REPEAT — both RED). r241 upgrades
fence 10 (WasmEngineFailClosed "restart hammer") from CONTENTION to
**PERSISTENT-FLAKE** (repeated across both legs on a solo-green tree).

## 4. arm_lines_deleted seed check

Seed: **0** — no route-macro family deletion has landed under W6. Git
log over `lib/smalt/arm_gateway/router.ex` +
`lib/smalt/egress_router.ex` shows no W6 deletion commit (newest is
`d092caa` court RED closure, not a family deletion). Current on-disk
line counts at execution time:

```
 4451 lib/smalt/arm_gateway/router.ex
 3648 lib/smalt/egress_router.ex
 8099 total
```

Since no W6 deletion has landed, `PRE_W6_SHA` is not yet pinned and
deleted = pre − post = 0 across both families. The ~2,400-2,800 arm +
~300 egress figures in `docs/jira/v26.10.16/PROJECTION-ARCH-PLAN.md`
§1 W6 remain a planning PROJECTION, not a measurement.

## 5. Gate standing (as-of-wrap)

Gate closed **TYPED-RED** per
`docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md`
(WO-2 attempt 3 of 3, closes per r240 fallback). Consequences held:
**NO version bump anywhere — version stays `26.10.16`** (verified
`mix.exs:4` = `"26.10.16"`); **no TWO-GREEN claims** in any standing.
