# SPC rolling control bands receipt (scripts/spc_gate.py)

```json
{
  "gate": "spc-bands",
  "verdict": "PASS",
  "tier": 0,
  "window": 30,
  "min_points": 8,
  "seeded": false,
  "events": [],
  "metrics": [
    {
      "metric": "nfr3_delta_rss_kb",
      "value": -31712.0,
      "n": 140,
      "center": -31712.0,
      "sigma": 3171.2,
      "z": 0.0,
      "tier": 0
    },
    {
      "metric": "nfr4_residue_tables",
      "value": 0,
      "n": 139,
      "center": 0.0,
      "sigma": 1.0,
      "z": 0.0,
      "tier": 0,
      "remediation": "bench-runner profile"
    }
  ]
}
```
