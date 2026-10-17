# i17b — bench-report: empty-window skip (integration fix)

Standing: PASS

## Change

Lease: `scripts/bench/report.py` (coordinator-approved integration fix).

`render_window` treated a bench dir with zero `.jsonl` (and zero wave-telemetry
files) as a defect and returned 1. A fresh wrap window (v26.10.17 bench/ holds
only README.md) is a legitimate empty state, so multi-window `main()` ORed its
way to exit 1 and broke `just bench-report`.

Patch: the empty case now prints a loud stderr note and returns 0:

```
print(f"[BENCH-REPORT] {version}: no jsonl — skipped", file=sys.stderr)
return 0
```

Fail-closed behavior for NON-empty windows is untouched: malformed rows still
set `skipped` and still return 1 (report.py:230-236).

## Verification (real output)

`just bench-report`, exit 0:

```
[BENCH-REPORT] v26.10.17: no jsonl — skipped
[BENCH-REPORT] v26.10.14: 44 file(s), 103 rows -> /Users/sac/smalt/docs/jira/v26.10.14/BENCH_RESULTS.md
[BENCH-REPORT] v26.10.16: 8 file(s), 252 rows -> /Users/sac/smalt/docs/jira/v26.10.16/BENCH_RESULTS.md
EXIT=0
```

Outputs unchanged + idempotent (sha256 identical across two consecutive runs;
the working-tree diff on BENCH_RESULTS.md files pre-dates this session — both
were already modified in the session-start git status snapshot):

```
SHA256 (docs/jira/v26.10.14/BENCH_RESULTS.md) = 26207707cf29b9db6184dea7c7e84281afdf881d7d7207c7840442da4cf1ce12
SHA256 (docs/jira/v26.10.16/BENCH_RESULTS.md) = 0f321aa4ae12bcb75d25d37b1abb03b0d6eb6c47ef68170464d46606f9927ac7
```

Negative probe (non-empty window with a malformed row still fails closed,
exit 1 — fixture under `tmp/i17b-negprobe/`, left in place after `rm` was
denied by permissions):

```
[WARN] skipping malformed line in .../vT/bench/bad.jsonl: {broken,,,json
[WARN] 1 malformed line(s) skipped
[BENCH-REPORT] FAIL(vT): 1 malformed row(s) skipped; report incomplete
[BENCH-REPORT] vT: 2 file(s), 1 rows -> .../out.md
EXIT=1
```

No git operations. No KD row covered (report.py is scripts/, not lib/).
