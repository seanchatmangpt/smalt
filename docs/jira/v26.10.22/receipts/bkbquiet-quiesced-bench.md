# BK-BQUIET — quiesced-machine bench re-measure attempt (5 SUSPECT-PERMANENT rows)

- **Standing**: PARTIAL_ALIVE — 4 of 5 rows re-measured PASS (load-typed), 1 FAIL typed louder
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-BQUIET
- Prescription source: `docs/jira/v26.10.22/receipts/bkrewit-wave1.md` +
  `bkbenchreg-registry-reconcile.md` (private port blocks + `just quiesce`)

## Embedded counts (real, before/after)

```
$ python3 scripts/receipt_index.py   (before addenda)  -> receipts=1507 sdk=61 total=1568 suspects=13
$ python3 scripts/receipt_index.py   (after addenda)   -> receipts=1513 sdk=61 total=1574 suspects=9
```

13 -> 9 at rerun time (receipts=1513 counts this receipt + concurrent-lane
landings). All 5 bench rows are absent from the SUSPECT list; the residual 9
suspects are unrelated rows owned by other lanes (bkaud2/bkbmir/bkclean3/
bkdrain/bkmcpsha/bkp20/bkqmon) — the fleet is live, so the residual is a
moving set; the load-bearing claim is only: zero of the 5 bench rows remain
SUSPECT. Original evidence
untouched: the b5 and c8 canonical jsonl files were snapshotted before their
drivers truncated/appended and restored byte-exact (sha256 verified:
b5 c6a97aca..., c8 338f5c86...).

## Quiesce attempt (step 1 — REFUSED, bounded wait expired BUSY)

```
$ just quiet-check
QUIET-CHECK REFUSE (typed violations):
  - stray beam pid 4111 cwd='' (not this checkout)
  - court port 9443 occupied / 8443 / 5672 / 5673 / 9444 occupied
  - concurrent suite/court processes: 1340 (foreign erts beam)
  - load 80.3/94.2 > threshold (16 cpus)
$ 15-min bounded poll (1 Hz: sysctl loadavg + beam census + 9443 LISTEN)
06:24:50 load=78.32/92.90 beams=31 9443=1  quiet_check=BUSY
06:38:47 load=104.30/97.26 beams=35 9443=1  quiet_check=BUSY
POLL-DONE STILL-BUSY
```

The fleet did NOT drain during the bounded window — load rose 78 -> 104.
Per dispatch, the pass proceeded on the residual load with it typed honestly
per lane below. No foreign beam was killed; no court port was touched.

## Per-lane results (real numbers, exit-captured, one lane per private block)

| lane | block | window load | result | verdict |
|---|---|---|---|---|
| b2 blob (TS SDK) | 39020..39025 | ~101-110 | 4/4 measures, 0 errors; 8k-put 562 ops/s (baseline 4,351) | PASS (load-typed) |
| b3 cosmos (TS SDK) | 39030..39035 | ~113 | 4/4 phases, 0 errors; point-read 577 ops/s (baseline 4,405) | PASS (load-typed) |
| b4 messaging (TS SDK) | 39040..39045 | ~120 | SB send 0/2000, 3 errs, CBS put-token 200 x1717; killed after ~25 min phase-(b) churn | FAIL (load-confounded) — stays SUSPECT-PERMANENT, louder |
| b5 python mirror | 39050..39055 | ~97-103 | 4/4 measures, 0 errors; blob puts 328 ops/s (baseline 917) | PASS (load-typed) |
| c8 chaos overlay | 39280..39285 | ~96 | 2 kills + reboots landed; reboot 18.05 s vs 2.7 s baseline; 0 portsquat; blob 100% / eh 89% / cosmos 78.4% in-window | PASS (load-typed) |

Full per-lane embedded outputs are in the five receipt addenda (RE-MEASURE
addendum, 2026-10-10.22, original evidence untouched in every receipt).
Re-measure jsonl rows live in scratch (`tmp/bkbquiet/*.jsonl`); the canonical
v26.10.14 jsonl files hold only the original rows (b5/c8 restored byte-exact).

## Honest typing

- The quiesce prescription could NOT be satisfied: the fleet was still at
  full load for the entire session. These are therefore **load-typed
  re-measures, not quiet-machine baselines**. They clear the NO-CONTEXT gap
  (real exit-captured runs, dated, embedded outputs, Context: solo) but do
  not certify quiet-machine numbers. The b4 FAIL is load-confounded: CBS
  put-tokens returned 200 throughout (1,717 witnessed) while SB sends
  delivered 0 — the face is the sender link (settlement within the 20 s op
  timeout under load, or the fixed link_credit=1000 / recycle-every-400
  idiom vs tree changes since 2026-10-15); the messaging owner must re-witness
  on a genuinely quiet machine before any flip.
- Harness finding (real, non-blocking): `bench_boot` gates readiness on the
  ARM port only; the egress port binds seconds later. b3's first driver
  attempt ECONNREFUSED'd; retried after a both-ports poll. Registry note
  updated.
- Registry DORMANT note corrected: SDK deps live at
  `verification/ts/node_modules` + system Python; the five lanes are
  runnable today (the old note pointed at deleted test/sdk-* paths).

## Files committed (explicit paths)

- docs/jira/v26.10.14/receipts/bench-02-blob-ts.md (RE-MEASURE addendum)
- docs/jira/v26.10.14/receipts/bench-03-cosmos-ts.md (RE-MEASURE addendum)
- docs/jira/v26.10.14/receipts/bench-04-messaging-ts.md (FAIL addendum, louder typing)
- docs/jira/v26.10.14/receipts/bench-05-python-mirror.md (RE-MEASURE addendum)
- docs/jira/v26.10.14/receipts/c8-chaos-cross.md (RE-MEASURE addendum)
- scripts/bench/REGISTRY.md (row flips + DORMANT-note correction)
- docs/jira/v26.10.22/receipts/bkbquiet-quiesced-bench.md (this receipt)

## Falsifier

1. Every addendum's embedded output is re-runnable: same drivers, same
   private blocks; a materially divergent result (not attributable to load)
   reopens the row.
2. Index residual: the 5 bench rows absent from the SUSPECT list at every
   rerun (addenda carry embedded outputs + Context). If any of the 5
   reappears as SUSPECT with no new receipt, the flip was regex-only and is
   refuted.
3. The b4 row stays SUSPECT-PERMANENT until a messaging-owner run on a
   genuinely quiet machine delivers >0 sends in the measured window; any PASS
   flip without that receipt refutes this typing.
4. Canonical jsonl integrity: b5/c8 originals byte-exact vs the pre-run
   sha256 snapshots recorded above; a drift refutes the restore.
