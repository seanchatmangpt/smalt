# Receipt — bench-01-core (lane B-1, shared bench infra)

Date: 2026-10-15 · Repo: /Users/sac/smalt @ main (post-518b31a) · No commits (per dispatch).

## Delivered

- `scripts/bench/lib.sh` — shared harness: `bench_machine_spec` (cpu/cores/ram/elixir/otp/darwin),
  `bench_boot <lane>` / `bench_down <pid>` (private port block per lane, MIX_ENV=test,
  auth_mode anonymous pinned via config/test.exs, all six listeners scoped — mirrors
  scripts/bench.py spawn), `bench_emit` (JSONL row), `bench_percentile` (p50/p95/p99),
  `bench_lane_ports` (bN -> 39000+10N..+5), `bench_result_file`.
- `justfile.d/15-bench.just` — `bench-machine`, `bench-report`; imported at the end of the
  root `Justfile` (single appended line, only lane allowed).
- `scripts/bench/report.py` — stdlib aggregator: `bench/*.jsonl` -> `BENCH_RESULTS.md`.
  Malformed lines warn-and-skip (witnessed: a concurrent lane wrote log output into its
  .jsonl; one bad lane must not block the aggregate).
- `scripts/bench/REGISTRY.md` — 12-lane registry: result-file names + port law
  (bN -> ports 39000+10N .. 39000+10N+5), with on-disk names reconciled for b6/b7.
- `docs/jira/v26.10.14/BENCH_RESULTS.md` — generated aggregate (regenerated clean after
  smoke rows removed).

## Witnessed execution

- `just bench-machine` (real output):
  `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- Boot gate: `bench_boot b1` -> pid 72437, `curl http://127.0.0.1:39010/metadata/endpoints`
  -> HTTP 200; `bench_down` -> port 39010 free, no orphan beam.
- `bench_percentile` smoke: input 12/5/99/40/7/33 -> `12.000 99.000 99.000`.
- JSONL validity: row keys exactly
  `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms, errors, machine}`.
- `just bench-report`: 3 files, 29 rows -> BENCH_RESULTS.md (includes concurrent lanes
  b6/b7 real rows already on disk); regenerated after removing B-1 smoke rows.

## Bugs found and fixed in-session (pre-admission, this diff)

1. OTP/elixir version parsing from `elixir --version` picked up double matches — replaced
   with `elixir -e 'IO.puts ...'` probes.
2. zsh does not word-split `set -- $var` — port parsing now uses `read ... <<<`.
3. `$0`-based repo resolution broke under `bash -c` — now `${BASH_SOURCE[0]}`-based.
4. `bench_down` unbound `$1` under `set -u` with empty pid — defaulted.

## Coordination

- Lanes must not edit scripts/bench/, 15-bench.just, Justfile, or REGISTRY.md.
- Observed on-disk lane files: b6-lro-sdk.jsonl, b7-store-beam.jsonl (names reconciled
  into the registry). b7's file contains one malformed log line — reported to no one
  here; flagged for coordinator: lane b7 is writing substrate log output into its
  result file. Coordinator action: b7 should write logs to a .log file, JSONL rows only
  to its result file.
