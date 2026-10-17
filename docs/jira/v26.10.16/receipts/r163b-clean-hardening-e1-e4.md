# Receipt — R163b (wave-telemetry CLEAN predicate hardening E1-E4)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `scripts/wave_telemetry.sh:90` (R163b E4 marker): tamper-evidence — MISSING rows
  carry a dedicated `missing:true` key, detected independently of the verdict
  string.
- `scripts/wave_telemetry.sh:177` (R163b marker): emit_row coherence —
  VERDICT=PASS RESULT=fail (or inverse) must not emit.
- `scripts/wave_telemetry.sh:258` (R163b marker): the D67 CLEAN/DIRTY predicate —
  CLEAN iff dispatch+complete rows exist, no duplicate (lane, wave) rows (E2),
  paired waves agree normalized (E3), complete rows agree PASS∧pass with numeric
  waits (E1), and no MISSING rows (E4).

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ scripts/wave_telemetry.sh report
wave-report: no telemetry at /Users/sac/smalt/docs/jira/v26.10.16/bench/wave-telemetry.jsonl — empty state, nothing recorded yet.
exit=0
```

(Empty-state verdict: the window's telemetry file has no rows yet, so the report
degrades loudly rather than faking a CLEAN.)

## W10 re-run (2026-10-16, docs lane W10)

```
$ scripts/wave_telemetry.sh report
Wave telemetry — 1 lane row(s) from /Users/sac/smalt/docs/jira/v26.10.16/bench/wave-telemetry.jsonl
lane            phase       queue_s  compile_s  substr_s   test_s  total_s  verdict
B               ?             0.000      0.000     0.000    0.000    0.000  MISSING
TOTAL (complete)              0.000      0.000     0.000    0.000    0.000  PASS=0 FAIL/other=0
DIRTY: MISSING rows present; no dispatch rows; no complete rows
EXIT=0
```

The E1-E4 predicates now operate on a non-empty telemetry file and degrade
LOUDLY (DIRTY verdict naming the missing evidence), never faking CLEAN.
Standing: PASS.
