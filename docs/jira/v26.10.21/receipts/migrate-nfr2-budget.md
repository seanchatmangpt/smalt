# Migrate NFR-2 budget receipt (50 resources under 30s)

**Standing:** PASS
Context: solo
Date: 2026-10-21

## NFR-2 budget test

```
$ cd /Users/sac/smalt/smalt-cli && .venv-cli/bin/python -m pytest tests/test_migrate_pipeline.py::test_pipeline_nfr2_50_resources_under_30s -v
configfile: pyproject.toml
collecting ... collected 1 item

tests/test_migrate_pipeline.py::test_pipeline_nfr2_50_resources_under_30s PASSED [100%]

============================== 1 passed in 0.03s ===============================
```

Measured wall (subprocess-timed, python `time.perf` around the same pytest
invocation): **0.205s** end to end including interpreter startup. The
fixture's 50-resource pipeline is fully in-process against loopback, so the
budget (30s) is met with ~150x headroom. Note: the test body is synthetic
in-process (no real wire hops per resource); it bounds pipeline orchestration
cost, not per-resource network latency.

## Full migrate family count

```
$ .venv-cli/bin/python -m pytest tests/test_migrate_{arm,e2e,enterprise_fixture,inject,manifest,pipeline,scan,verify}.py -q
......................................................................   [100%]
70 passed in 13.33s
```

Family census: 8 files, 70 tests, 0 skipped, 0 failed (includes the NFR-2
budget test and the verify/e2e suites receipted separately in
`m4sbfix-verify-zero-skip.md`).

## Standing

PASS — NFR-2 budget met (measured 0.205s vs 30s bound); full migrate family
green at 70/70 with zero skips.
