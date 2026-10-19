# SPC rolling control bands receipt (scripts/spc_gate.py)

```json
{
  "gate": "spc-bands",
  "verdict": "FAIL",
  "tier": 3,
  "window": 30,
  "min_points": 8,
  "seeded": true,
  "events": [],
  "metrics": [
    {
      "metric": "native_stage_ms.parse",
      "value": 120.36,
      "n": 300,
      "center": 100.0,
      "sigma": 5.09,
      "z": 4.0,
      "tier": 3,
      "event": {
        "spc_drift": [
          "native_stage_ms.parse",
          3,
          120.36
        ]
      },
      "remediation": "fail-closed: orphaned-key dump + bench-runner profile (3-sigma)"
    },
    {
      "metric": "nfr4_residue_tables",
      "value": 0.0,
      "n": 0,
      "verdict": "SEEDED",
      "center": 0.0,
      "note": "seed mode: bands established from baseline"
    }
  ],
  "orphaned_keys": [
    {
      "metric": "native_stage_ms.parse",
      "value": 120.36,
      "z": 4.0
    }
  ]
}
```
