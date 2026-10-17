# Receipt — R36 (bench report.py fail-closed on malformed rows + wave-telemetry split)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `scripts/bench/report.py` — (a) wave-telemetry jsonl split out of bench
  aggregation (EXCLUDED, listed under "Non-op records"); (b) fail-closed
  epilogue: report still written, but any skipped/malformed row forces
  exit 1 with `[BENCH-REPORT] FAIL`.

## Verification (2026-10-15, W2 docs lane, unedited A/B output)

```
$ BENCH_RESULTS_DIR=/tmp/r36clean BENCH_REPORT_OUT=/tmp/r36-clean.md python3 scripts/bench/report.py; echo "clean-exit=$?"
[BENCH-REPORT] 1 file(s), 0 rows -> /tmp/r36-clean.md
clean-exit=0
```

```
$ BENCH_RESULTS_DIR=/tmp/r36bad BENCH_REPORT_OUT=/tmp/r36-bad.md python3 scripts/bench/report.py; echo "bad-exit=$?"
[WARN] skipping malformed line in /tmp/r36bad/a1-bad.jsonl: {"garbage":true
[WARN] 1 malformed line(s) skipped
[BENCH-REPORT] FAIL: 1 malformed row(s) skipped; report incomplete
[BENCH-REPORT] 1 file(s), 0 rows -> /tmp/r36-bad.md
bad-exit=1
```

The flip IS the non-vacuity proof: clean dir exits 0, one malformed row
flips the verdict to exit 1 while the report file is still emitted.
