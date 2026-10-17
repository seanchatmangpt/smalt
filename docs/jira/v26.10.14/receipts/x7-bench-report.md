# X-7 Receipt: `just bench-report` wiring + BENCH_RESULTS.md regeneration

Lane: X-7 (B-12 finding). Date: 2026-10-15. No commits (per dispatch).

## Finding on arrival

`justfile.d/15-bench.just` already contained a `bench-report` recipe (B-1 shared
infra, invoking `python3 scripts/bench/report.py`). The real gap was in the aggregator and data: B-12's
manual BENCH_RESULTS.md had been replaced by report.py output that (a) silently
dropped every b8 row (all 6 jsonl lines truncated — missing closing brace) and
(b) rendered non-op record classes as fake "?" op rows.

## Changes

1. **Recipe**: already present (`justfile.d/15-bench.just` `bench-report:` →
   `python3 scripts/bench/report.py`). Verified invoking, not rewritten.
2. **Data repair** (`docs/jira/v26.10.14/bench/b8-amqp-beam.jsonl`): 6 lines
   were truncated JSON (missing outer closing `}`; b8 lane is complete with
   receipt bench-08-amqp-beam.md on disk). Appended the missing `}` per line;
   all 6 lines now parse. No values altered.
   (b8 is registry-assigned to another file name but this file is what's on
   disk for the AMQP BEAM lane; left in place.)
3. **Aggregator** (`scripts/bench/report.py`):
   - Split record classes: op rows (`op` key + numeric `ops_per_sec`) render
     as table rows; non-op records (b11 chaos/TLS run records, b4 meta, b6
     phase blobs, b7 meta/race records) render as one summary line per file
     with kind labels — never fake op rows, never restated numbers.
   - Added a Methodology section pointing at `scripts/bench/REGISTRY.md`
     (row schema) and the per-lane receipts `bench-*.md` for the SDK→BEAM
     multiplier narrative (count-restatement ban: narrative lives in receipts,
     report points, does not restate).
   - Kept stdlib-only, deterministic, sorted iteration → idempotent.

## Witness

- `just bench-report` runs; exits 0.
- Regenerated `docs/jira/v26.10.14/BENCH_RESULTS.md` includes late lanes:
  - b2 blob TS: 4 op rows
  - b3 cosmos TS: 4 op rows (file landed mid-session)
  - b4 servicebus: 1 op row (send, 3 errors — KD candidate note in jsonl)
  - b5 blob + cosmos: 2+2 op rows
  - b7 store-beam: 4 op rows (put 1.04M ops/s, get 1.83M ops/s)
  - b8 amqp-beam: 6 op rows incl. `frame_transfer_encdec` 41,312 ops/s (the
    frame tier row B-12's manual table missed) — 0 rows before repair
  - b9 eh-beam: 4 op rows + sb-lock 1 row
- 28 op rows, 9 files. Double-run diff-clean: md5 identical
  (576c5fbeefb9a3f58fa89c4f9ab33679 across back-to-back runs).
- Non-op records listed: b11 3 (chaos_kill, tls_churn, phase-record), b4 1
  (meta), b6 9 (phase-record), b7 23 (beam_meta/done/insert_new_race_64/
  list_prefix_10k).

## Standing

ALIVE: recipe invoked, file regenerated from disk jsonl, idempotency witnessed
by double-run md5 equality.

## Re-witness 2026-10-16

```
$ just bench-report 2>&1 | tail -4
[BENCH-REPORT] FAIL(v26.10.14): 16 malformed row(s) skipped; report incomplete
[BENCH-REPORT] v26.10.14: 44 file(s), 97 rows -> /Users/sac/smalt/docs/jira/v26.10.14/BENCH_RESULTS.md
[BENCH-REPORT] v26.10.16: 2 file(s), 5 rows -> /Users/sac/smalt/docs/jira/v26.10.16/BENCH_RESULTS.md
error: recipe `bench-report` failed on line 10 with exit code 1
```

Verdict differs from the original receipt: the recipe now FAILs (exit 1) because
16 bench jsonl rows are Elixir-map-syntax rather than JSON (a7/a8 lanes); the
report is still written (44 files, 97 rows for v26.10.14). Regeneration works;
the malformed rows are a pre-existing data defect, not a reporter defect.
