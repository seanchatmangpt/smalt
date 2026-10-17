# Receipt — R147 (r103 c6-corpus receipt correction, SKIP → RESOLVED)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

R147 corrected two factually wrong defect claims in
`docs/jira/v26.10.16/receipts/r103-c6-corpus.md` (see its "Resolution
(2026-10-16, repair lane R147 per D79 findings)" section): (1) "azure.monitor
absent from every venv" was false — `test/sdk-python/.venv-rg` carries
azure-monitor-query 2.0.0; (2) "exit is a hard traceback, not a typed skip" was
stale — R117 landed the loud-skip path (`scripts/bench/c6_sentinel_rg.py:34-43`).

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ python3 scripts/bench/c6_sentinel_rg.py
SKIP: azure SDK deps not importable (No module named 'azure'); lane C-6 requires azure-monitor-query + azure-mgmt-resourcegraph in the venv
exit=3
```

## W10 re-run (2026-10-16, docs lane W10)

```
$ python3 scripts/bench/c6_sentinel_rg.py
SKIP: azure SDK deps not importable (No module named 'azure'); lane C-6 requires azure-monitor-query + azure-mgmt-resourcegraph in the venv
EXIT=3
```

The c6 loud-SKIP (exit 3, no fake pass) re-witnessed; correction stands.
Standing: PASS.
