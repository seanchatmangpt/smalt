# Wave Telemetry — v26.10.15 (lane S-8)

# Wave Telemetry Spec

Land idea: wave-level wall-clock instrumentation — the next baseline reads a
file, not archaeology. Lanes record their own wall-clock waits as JSONL rows;
`just wave-report` aggregates. Incremental adoption: no lane is retrofitted
in this window.

## Components

| file | role |
|---|---|
| `scripts/wave_telemetry.sh` | `emit` / `wrap` / `report` subcommands |
| `justfile.d/19-wave-telemetry.just` | `just wave-report` |
| `docs/jira/v26.10.14/bench/wave-telemetry.jsonl` | default row store (created on first emit) |

## Schema

One JSON object per line, same store as the v26.10.14 bench rows
(`scripts/bench/lib.sh` shape). Emitted by `emit`, validated before write —
skip-loud on malformed env (warn to stderr, write nothing, exit 0; a lane
must never fail because telemetry failed).

```json
{"lane":"s3","queue_wait_s":1.5,"compile_wait_s":12.25,"substrate_wait_s":8,"test_wall_s":31.4,"result":"pass","total_s":53.15,"ts":"2026-10-16T02:03:51Z"}
```

| key | type | validation |
|---|---|---|
| `lane` | string | required, non-empty (`LANE_ID`) |
| `queue_wait_s` | number | seconds (`QUEUE_WAIT_S`), default 0 |
| `compile_wait_s` | number | seconds (`COMPILE_WAIT_S`), default 0 |
| `substrate_wait_s` | number | seconds (`SUBSTRATE_WAIT_S`), default 0 |
| `test_wall_s` | number | seconds (`TEST_WALL_S`), default 0 |
| `result` | enum | `pass` or `fail` (`RESULT`), required |
| `total_s` | number | computed: sum of the four waits |
| `ts` | string | UTC timestamp at emit time |

Rejected env: missing/empty `LANE_ID`, non-numeric wait, `RESULT` not
pass/fail → nothing written.

## Usage

### emit (lane-side, at exit)

A lane sets env vars and calls emit at exit:

```sh
LANE_ID=s3 QUEUE_WAIT_S=1.5 COMPILE_WAIT_S=12.25 \
SUBSTRATE_WAIT_S=8 TEST_WALL_S=31.4 RESULT=pass \
  scripts/wave_telemetry.sh emit
```

### wrap (convenience, incremental adoption)

Records wall time around any command and emits with `TEST_WALL_S`; the
command's exit status becomes `RESULT` and is propagated as the wrapper's
exit status.

```sh
scripts/wave_telemetry.sh wrap -- just test-sdk
```

Both accept `--out <path>` to redirect the row (used for scratch/demo runs;
production rows go to the default `wave-telemetry.jsonl`).

Adoption policy: lanes adopt `wrap` incrementally, one command at a time.
No retrofit in this window — the S-8 receipt demonstrates the schema with a
`--out` scratch file instead.

### report

```sh
just wave-report        # or: scripts/wave_telemetry.sh report
```

Prints a per-lane wait table (queue/compile/substrate/test/total, sorted by
total desc) plus totals and pass/fail counts. Empty-state honest: with no
store file it prints "empty state, nothing recorded yet" and exits 0.

## Define/Measure contract (v26.10.15)

**Define**: next window's baseline for lane wall-clock cost is a file —
`docs/jira/v26.10.14/bench/wave-telemetry.jsonl` — not session archaeology.
Every lane that adopts `wrap`/`emit` contributes one row per run; receipts
in v26.10.15 carry a wall-clock section citing real rows from this file.

**Measure**: P-0's baseline doc (`docs/jira/v26.10.15/00-*`) had not landed
when this spec was written — cross-link pending; when it lands, this section
binds to its exit criteria (receipts carry a wall-clock section next window)
and `just wave-report` output becomes the Measure evidence.

Related: `docs/jira/v26.10.15/01-substrate-daemon.md` (F2 already measures
daemon-mode wall against the 10.8s boot class — same quantity, different
instrument).

## See Also

`scripts/bench/lib.sh` (row shape) · `scripts/bench/report.py` (bench
aggregation, same pattern) · `docs/jira/v26.10.14/receipts/s8-wave-telemetry.md`
(receipt with demo output)
