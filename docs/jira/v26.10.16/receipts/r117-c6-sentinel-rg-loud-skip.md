# Receipt — R117 (c6_sentinel_rg loud skip)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `scripts/bench/c6_sentinel_rg.py` — the lane exits loudly (typed SKIP,
  exit 3) when the azure SDK deps are absent instead of an untyped traceback
  (the r103 W3/W4 defect class).

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ python3 scripts/bench/c6_sentinel_rg.py; echo "EXIT=$?"
SKIP: azure SDK deps not importable (No module named 'azure'); lane C-6 requires azure-monitor-query + azure-mgmt-resourcegraph in the venv
EXIT=3
```

Exit-code contract honored: 3 = harness-skip, loud, never a fake pass.
