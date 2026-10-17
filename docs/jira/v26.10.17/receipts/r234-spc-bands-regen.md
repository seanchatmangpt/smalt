# r234 — spc-bands regeneration from scripts/spc_gate.py (rolling window)

- Date: 2026-10-17
- Lane: I2 (WO-3)
- Subject: commit 650a8ff `chore(spc): regen spc-bands from spc_gate.py (n=103; band n bumps 96->100, 95->99)`; artifact `docs/jira/v26.10.16/sdk-results/spc-bands.md`
- Standing: PASS

## Command

```
$ python3 scripts/spc_gate.py
```

## Real output (2026-10-17, /Users/sac/smalt)

```
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
      "n": 112,
      "center": -31712.0,
      "sigma": 3171.2,
      "z": 0.0,
      "tier": 0
    },
    {
      "metric": "nfr4_residue_tables",
      "value": 0,
      "n": 111,
      "center": 0.0,
      "sigma": 1.0,
      "z": 0.0,
      "tier": 0,
      "remediation": "bench-runner profile"
    }
  ]
}
EXIT=0
```

## Regen behavior (honest observation)

`git diff -- docs/jira/v26.10.16/sdk-results/spc-bands.md` after the run:

```
-      "n": 104,
+      "n": 112,
...
-      "n": 103,
+      "n": 111,
```

Only the sample counts `n` moved (104→112, 103→111); `value`, `center`,
`sigma`, `z` and verdict are unchanged. This is the gate's designed rolling
behavior — each run appends points to the telemetry corpus, so `n` grows per
run and regen is **not** byte-idempotent across runs; the sha256 changes even
when the control state is identical:

```
before: 5bc693a4d4b33073e79630965004731ee8520b2de9a9604a6f785159c1a7520f
after:  5e12e0d2022fd5d03a013b2b27649951b203995df2df6a704e3a6f9189469ac4
EXIT=0
```

Control state is stable at tier 0 / zero SPC events across both runs. The
commit's `n=103` baseline has since grown to `n=111/112` — same bands, more
corpus.

## Notes

- `scripts/doctor.py:463` delegates to this same gate — one bands file, one
  receipt.
