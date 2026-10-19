# SPC rolling control bands receipt (scripts/spc_gate.py)

```json
{
  "gate": "spc-bands",
  "verdict": "EVENT",
  "tier": 1,
  "window": 30,
  "min_points": 8,
  "seeded": true,
  "events": [
    {
      "spc_drift": [
        "native_stage_ms.parse",
        1,
        107.635
      ]
    }
  ],
  "metrics": [
    {
      "metric": "native_stage_ms.parse",
      "value": 107.635,
      "n": 300,
      "center": 100.0,
      "sigma": 5.09,
      "z": 1.5,
      "tier": 1,
      "event": {
        "spc_drift": [
          "native_stage_ms.parse",
          1,
          107.635
        ]
      }
    },
    {
      "metric": "nfr4_residue_tables",
      "value": 0.0,
      "n": 0,
      "verdict": "SEEDED",
      "center": 0.0,
      "note": "seed mode: bands established from baseline"
    }
  ]
}
```
