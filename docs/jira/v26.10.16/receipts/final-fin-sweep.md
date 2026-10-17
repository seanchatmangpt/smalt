# Final fin sweep — 4-generator + idempotence (terminal)

**Standing**: ALIVE
**Date**: 2026-10-17
**Subject**: /Users/sac/smalt @ main (8361816, pre-sweep dirty tree: projection W1 in flight)
**Window**: v26.10.16 terminal fin sweep, post-KD-94 / semantic-guard landings.

## Commands and real output

```
$ python3 scripts/receipt_index.py   # run 1 → exit 0
$ python3 scripts/receipt_index.py   # run 2 → exit 0
$ sha256sum docs/jira/v26.10.16/RECEIPTS.md docs/jira/v26.10.16/receipts/INDEX.md
069707a63433796dbea128d69356e62219169ed7c08c46caf566b3a135b43d8f  docs/jira/v26.10.16/RECEIPTS.md
a68cc7790d06b1da1d0879bcc2624b1744c3c8da4c9a30c27afdcef835b11b06  docs/jira/v26.10.16/receipts/INDEX.md
$ diff run1.out run2.out   → identical (RI-IDEMPOTENT)
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.14/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/receipts/INDEX.md
```

```
$ python3 scripts/bench/report.py    # run 1 → exit 0
$ python3 scripts/bench/report.py    # run 2 → exit 0
$ sha256sum docs/jira/v26.10.16/BENCH_RESULTS.md
54b9472b0cc6ea62adbf743cedbc961960853fa8750187f0c120bb2b39aeec02  docs/jira/v26.10.16/BENCH_RESULTS.md
$ diff run1.out run2.out   → identical (BR-IDEMPOTENT)
[BENCH-REPORT] v26.10.14: 44 file(s), 103 rows -> docs/jira/v26.10.14/BENCH_RESULTS.md
[BENCH-REPORT] v26.10.16: 8 file(s), 252 rows -> docs/jira/v26.10.16/BENCH_RESULTS.md
```

```
$ python3 scripts/sdk_coverage.py --check → exit 0
=== window v26.10.14 ===
SDK COVERAGE MATRIX — machine summary
divergence register: 94 KD rows loaded
...
GATE: OK — every cell pass / registered / sim-pass / missing-registered
```

```
$ python3 scripts/gen_error_codes.py --check → exit 0
docs/ERROR_CODES.md up to date
```

## 4-generator table

| Generator | Command | Exit | Idempotence (2×) | Moved vs HEAD |
|---|---|---|---|---|
| receipt-index | `python3 scripts/receipt_index.py` | 0 | PASS — byte-identical reruns (diff empty) | RECEIPTS.md +2 lines, receipts/INDEX.md 159→161 receipts (193→195 total files) in v26.10.16; v26.10.14 321 receipts / 370 total (+2/+2) |
| bench-report | `python3 scripts/bench/report.py` | 0 | PASS — byte-identical reruns (diff empty) | BENCH_RESULTS.md unchanged on disk (sha256 above); 44 files/103 rows (v26.10.14) + 8 files/252 rows (v26.10.16) |
| sdk-coverage | `python3 scripts/sdk_coverage.py --check` | 0 | n/a (--check, fail-closed gate) | GATE OK — 94 KD rows, every cell pass/registered/sim-pass/missing-registered |
| gen-error-codes | `python3 scripts/gen_error_codes.py --check` | 0 | n/a (--check, drift-fenced) | up to date — 98 error-code table rows in docs/ERROR_CODES.md |

Expected movement confirmed: receipt counts moved past the expected marks
(317+ → 321 v26.10.14 receipts / 366+ → 370 total receipt files; 49+ → 52 bench
files total 44+8). Bench rows grew to 252 in v26.10.16.

## SUSPECT census (informational, pre-existing)

`receipt_index.py` run 2 flagged 16 SUSPECT receipts in v26.10.14
(06-blob-x-ms-date-unvalidated, a2-cas-contention, bench-02-blob-ts,
bench-03-cosmos-ts, bench-04-messaging-ts, bench-05-python-mirror,
bench-12-consolidation, c4-kv-cosmos, c8-chaos-cross, errc4-hdr, fin24-p5-doc,
fin30-landing, fin32-wrap-final, fin33-planning-summary, lc1-8hop-tax-chain,
lc2-tco-ledger) — all in the closed v26.10.14 window; v26.10.16: 0 SUSPECT.
No receipt in this window is flagged.

## Verdict

All four generators green, both double-run generators byte-identical, both
fail-closed checks exit 0. Fin sweep passes.
