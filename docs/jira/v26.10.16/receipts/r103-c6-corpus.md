# R103: c6 sentinel RG bench corpus

Standing: RESOLVED (both defect claims corrected; see Resolution)
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `scripts/bench/c6_sentinel_rg.py` (+26 diff)

## Claim

c6 corpus repairs landed.

## Re-run evidence (attempted; loud skip, never a faked pass)

```
$ python3 scripts/bench/c6_sentinel_rg.py
Traceback (most recent call last):
  File "scripts/bench/c6_sentinel_rg.py", line 34, in <module>
    from azure.core.credentials import AccessToken
ModuleNotFoundError: No module named 'azure'

$ smalt-cli/.venv-cli/bin/python scripts/bench/c6_sentinel_rg.py
Traceback (most recent call last):
  File "scripts/bench/c6_sentinel_rg.py", line 37, in <module>
    from azure.monitor.query import LogsQueryClient, LogsQueryStatus
ModuleNotFoundError: No module named 'azure.monitor'
```

## Verdict

SKIP. `azure.monitor` (monitor-query) is absent from every venv on this host; c6 cannot
execute locally, and the script has no offline/simulated mode (`grep -n "offline|add_argument"`
→ only `def main():` at line 374). Exit is a hard traceback, not a typed skip — recording
that as its own open defect: a lane that cannot run should exit 3 with a named reason.

## Resolution (2026-10-16, repair lane R147 per D79 findings)

Both defect claims above were factually wrong and are corrected; the original text is
retained above as history.

1. **"absent from every venv on this host" — FALSE.** `test/sdk-python/.venv-rg` carries
   `azure-monitor-query 2.0.0` + `azure-mgmt-resourcegraph 8.0.1` (witnessed:
   `test/sdk-python/.venv-rg/bin/python -c "import azure.monitor.query, azure.mgmt.resourcegraph"`
   → `2.0.0 8.0.1`, exit 0). A full c6 pass under that venv already exists:
   `docs/jira/v26.10.14/receipts/c6-sentinel-rg.md` +
   `docs/jira/v26.10.14/bench/c6-sentinel-rg.jsonl` (2026-10-15, 5 records, errors=0 on
   all — includes `rg_project_top100` n=5998 errors=0 and sentinel
   `kql_take100000_cap_under_load` cap_violations=0).
2. **"exit is a hard traceback, not a typed skip" — FALSE (stale).** R117 landed the
   loud-skip path; witnessed this session on the current script:

```
$ python3 scripts/bench/c6_sentinel_rg.py
SKIP: azure SDK deps not importable (No module named 'azure'); lane C-6 requires azure-monitor-query + azure-mgmt-resourcegraph in the venv
exit=3
```

   (`scripts/bench/c6_sentinel_rg.py:34-43` — try/except ImportError → `SKIP:` line +
   `sys.exit(3)`.)

Verdict: both claims resolved; no open defect remains on c6 from this receipt. The
"absent from every venv" claim traced to probing only the repo-root and
`smalt-cli/.venv-cli` interpreters, missing `test/sdk-python/.venv-rg`.
