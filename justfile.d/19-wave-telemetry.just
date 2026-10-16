# 19-wave-telemetry — wave-level wall-clock telemetry (lane S-8, v26.10.15).
# Spec: docs/jira/v26.10.15/WAVE_TELEMETRY.md

# Aggregate docs/jira/v26.10.14/bench/wave-telemetry.jsonl into a per-lane wait table.
# Empty-state honest: prints a clear empty message when nothing has been recorded.
wave-report:
    @scripts/wave_telemetry.sh report
