# I17 — Bench decision (wrap window, no new bench lanes)

Standing: PARTIAL_ALIVE — deliverable 1 landed; deliverable 2 (exit-0 confirmation) FAILED with a real defect in `scripts/bench/report.py`, not fixed (lane lease forbids `scripts/bench/` edits).

Lane: I17 of `docs/jira/v26.10.17/_LANES.md`. Lease: `docs/jira/v26.10.17/bench/` + bench result regen input. No git actions taken.

## Deliverable 1 — bench/README.md — LANDED

Created `docs/jira/v26.10.17/bench/README.md` (one line):

```
v26.10.17: no new bench lanes — wrap window; BENCH_RESULTS.md minted at fin-sweep via just bench-report (multi-window mode emits no file for a bench dir with no jsonl).
```

## Deliverable 2 — `just bench-report` exit-0 confirmation — FAILED

Real command output (repo root /Users/sac/smalt, 2026-10-17):

```
$ just bench-report; echo "EXIT=$?"
no .jsonl results in /Users/sac/smalt/docs/jira/v26.10.17/bench
[BENCH-REPORT] v26.10.14: 44 file(s), 103 rows -> /Users/sac/smalt/docs/jira/v26.10.14/BENCH_RESULTS.md
[BENCH-REPORT] v26.10.16: 8 file(s), 252 rows -> /Users/sac/smalt/docs/jira/v26.10.16/BENCH_RESULTS.md
error: recipe `bench-report` failed on line 10 with exit code 1
EXIT=1
```

Reproduced via `python3 scripts/bench/report.py` directly: exit 1, same stderr line.

### Root cause

`scripts/bench/report.py` lines 90–92 (`render_window`):

```python
if not files and not wave_files:
    print(f"no .jsonl results in {results_dir}", file=sys.stderr)
    return 1
```

The multi-window `main()` loop (lines 255–259) ORs every window's return code, so one bench dir with no jsonl fails the whole run. The v26.10.17 `bench/` dir holds only `README.md` (no `.jsonl`), so v26.10.14 and v26.10.16 reports regenerate fine but the overall exit is 1.

### Contradiction with the lane task premise

The lane task (and the new README text) claims "multi-window mode emits no file for a bench dir with no jsonl". Reality: it emits no file, yes — but it also exits 1, failing the recipe. The exit-0 confirmation therefore does not hold as stated. Two lawful resolutions, both outside this lane's lease:

1. Coordinator edits `report.py` to `return 0` (or `continue` with a stderr note) for an empty bench dir in multi-window mode only; or
2. Coordinator accepts the exit-1-is-correct semantics and rewords the README line.

## What was NOT done

- No edits to `scripts/bench/` or `REGISTRY.md` (lane lease).
- No git actions.
- v26.10.14/v26.10.16 BENCH_RESULTS.md regen diffs were produced in-tree by the run and left as-is (v26.10.16 regen diff already in tree per lane task).
