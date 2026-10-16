# 15-bench — benchmark wave shared infra (lane B-1)
# Machine spec + aggregation of all lane JSONL results into BENCH_RESULTS.md.

# Print the machine spec block every bench lane must embed in its results.
bench-machine:
    @bash -c 'source scripts/bench/lib.sh && bench_machine_spec'

# Aggregate all docs/jira/v26.10.14/bench/*.jsonl into BENCH_RESULTS.md.
bench-report:
    @python3 scripts/bench/report.py

