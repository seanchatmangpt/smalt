# External workflow receipt: wf5-edge-resilience (py)

Workflow: wf5-edge-resilience
Lang: py
Window: v26.10.19
SUBJECT_SHA: 64f6099663a4ec32fd9478c4c39fca49ab1961f8
Profile: primary-tier external suite (official Azure SDKs; surfaces: sentinel, cap:monitor-metrics)
Generated: 2026-10-19T17:10:50.965373+00:00

## Cell tags

sentinel:abort: sentinel/abort BLOCKED

## Runner output tail

```
[py-lane] substrate receipt: {"block": "v1", "ports": [39710, 39711, 39712, 39713, 39714, 39715], "pid": 14087, "reused": false, "marker": "/tmp/smalt-substrate-state/markers/v1.boot.json", "auth": "enforce"}

no tests ran in 0.00s
[py-lane] pytest rc=4
ERROR: file or directory not found: wf5
```
