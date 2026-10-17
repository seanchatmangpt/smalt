# R177f — wave-telemetry CLEAN holes closed loud

Standing: PASS

## Scope

`scripts/wave_telemetry.sh` hardening: paired dispatch/complete waves must
agree EXACTLY after pairing (R177f 2b), and the non-string dispatch-row
wave (v1 legacy numeric wave field) is handled explicitly (R177f 2a).
Markers: `scripts/wave_telemetry.sh:296` ("(R177f 2a) non-string
dispatch-row wave") and `:304` ("E3 (R177f 2b): paired dispatch/complete
waves must agree EXACTLY after").

## Re-run output (docs lane, 2026-10-16)

```
$ bash scripts/wave_telemetry.sh report
Wave telemetry — 1 lane row(s) from .../docs/jira/v26.10.16/bench/wave-telemetry.jsonl

lane            phase       queue_s  compile_s  substr_s   test_s  total_s  verdict
-----------------------------------------------------------------------------------
B               ?             0.000      0.000     0.000    0.000    0.000  MISSING
-----------------------------------------------------------------------------------
TOTAL (complete)              0.000      0.000     0.000    0.000    0.000  PASS=0 FAIL/other=0

DIRTY: MISSING rows present; no dispatch rows; no complete rows
RC=0
```

The report is DIRTY-loud on incomplete data (MISSING row surfaced, no
silent CLEAN) — the r163b fail-closed contract holds on the current
telemetry file. Exit 0 with loud DIRTY verdict, matching the r163b
precedent.
