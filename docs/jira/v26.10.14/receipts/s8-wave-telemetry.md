# Receipt: s8-wave-telemetry

- **lane**: S-8 (v26.10.15 idea lane)
- **work order**: wave-level wall-clock instrumentation (land idea)
- **repo**: /Users/sac/smalt, branch main @ 518b31a (uncommitted, per lane law: no commits)
- **date**: 2026-10-16

## Landed

| file | role |
|---|---|
| `scripts/wave_telemetry.sh` | `emit` / `wrap` / `report` subcommands (bash, stdlib python3 only) |
| `justfile.d/19-wave-telemetry.just` | `just wave-report` recipe |
| `justfile` | +1 line: `import 'justfile.d/19-wave-telemetry.just'` (wired so root `just` sees the recipe) |
| `docs/jira/v26.10.15/WAVE_TELEMETRY.md` | spec: schema, emit/wrap/report usage, Define/Measure contract |
| `docs/jira/v26.10.14/receipts/s8-wave-telemetry.md` | this receipt |

No retrofit of existing lanes (adoption is incremental per the work order).

## Schema (one JSONL row, same store as bench rows)

```json
{"lane":"fake-lane","queue_wait_s":1.5,"compile_wait_s":12.25,"substrate_wait_s":8,"test_wall_s":31.4,"result":"pass","total_s":53.150,"ts":"2026-10-16T02:33:15Z"}
```

Validation on emit is skip-loud: missing/empty `LANE_ID`, non-numeric wait,
or `RESULT` not pass/fail → warn on stderr, write nothing, exit 0. Witnessed
malformed-env cases: empty LANE_ID, `QUEUE_WAIT_S=abc`, `RESULT=maybe` —
all three skipped with rc=0 and zero rows written.

## Demonstration (scratch path via --out, real jsonl untouched)

2 sample rows for a fake lane into `$(mktemp -d)/wave-telemetry-scratch.jsonl`
(scratch removed after witnessing; real
`docs/jira/v26.10.14/bench/wave-telemetry.jsonl` confirmed absent — no demo
pollution):

```json
{"lane":"fake-lane","queue_wait_s":1.5,"compile_wait_s":12.25,"substrate_wait_s":8,"test_wall_s":31.4,"result":"pass","total_s":53.150,"ts":"2026-10-16T02:33:15Z"}
{"lane":"fake-lane-2","queue_wait_s":0,"compile_wait_s":0,"substrate_wait_s":0,"test_wall_s":0.245,"result":"pass","total_s":0.245,"ts":"2026-10-16T02:33:15Z"}
```

Row 2 was produced by the wrap path:
`scripts/wave_telemetry.sh wrap --out "$SCRATCH" -- sleep 0.2` (rc=0; a
`wrap -- false` run also witnessed rc=1 propagation with a skip-loud emit due
to unset LANE_ID).

`report` on the scratch file (witnessed output):

```
Wave telemetry — 2 lane row(s) from .../wave-telemetry-scratch.jsonl

lane              queue_s  compile_s  substr_s   test_s  total_s  result
------------------------------------------------------------------------
fake-lane           1.500     12.250     8.000   31.400   53.150  pass
fake-lane-2         0.000      0.000     0.000    0.245    0.245  pass
------------------------------------------------------------------------
TOTAL               1.500     12.250     8.000   31.645   53.395  pass=2 fail=0
```

## Verification commands (actual exits)

- `bash -n scripts/wave_telemetry.sh` → 0 (after fixing one case-statement
  typo during construction; syntax-check witnessed post-fix)
- `just wave-report` (root justfile, recipe imported) → 0, empty-state
  message: `no telemetry at .../wave-telemetry.jsonl — empty state, nothing
  recorded yet.`
- `scripts/wave_telemetry.sh report --out-file <scratch>` → table above
- scratch removal → `scratch removed`; real jsonl still absent

## Falsifiers / boundaries

- P-0's baseline doc `docs/jira/v26.10.15/00-*` has NOT landed — the spec's
  Define/Measure section marks the cross-link pending, not claimed.
- Empty-state honesty witnessed on the default path (file absent → exit 0
  with explicit empty message).
- Wall-clock numbers in the demo are synthetic (fake lane + `sleep 0.2`);
  first real rows arrive when lanes adopt wrap next window.

## Standing

ALIVE at the demonstrated surface (emit/wrap/report with --out scratch +
empty-state report). Real-wave standing is UNKNOWN until lanes adopt
telemetry and the store carries production rows.
