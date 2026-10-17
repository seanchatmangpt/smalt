# PY-7: Real azure-resourcegraph + azure-monitor-query SDKs vs smalt ResourceGraph / Sentinel / Log Analytics (v26.10.16 re-run)

- Date: 2026-10-16
- Repo: /Users/sac/smalt @ main, v26.10.16 window
- Probe: `test/sdk-python/py_resourcegraph_monitor.py` (venv `.venv-rg`)
- Port env: probe now reads `SMALT_ARM_BASE` + `SMALT_EGRESS_BASE` (lane-351);
  run against the lane-351 substrate (ports 39360-39364), MIX_ENV=test,
  STS bearer minted from the substrate STS over ARM 39362.
- Exit: 0

## Verdict: PASS — 11/11 probes pass (0 fail, 0 error)

Embedded probe output (lane run, ARM 39362 / egress 39363):

```
== PY-7 ResourceGraph + Log Analytics (Sentinel) real-SDK probes ==
[seed] 150 storage accounts created under sub-py7
PASS rg.query $top=150 (full page, no truncation) :: count=150 totalRecords=150 resultTruncated=False
PASS rg.skipToken pagination no dupes, terminates :: 3 pages x<=50, 150 rows, no dupes
PASS rg.default $top=100 + skipToken present :: default $top: count=100 totalRecords=150 skipToken present
PASS rg.string subscriptions -> 400 InvalidParameter :: typed client refuses str subscriptions client-side (SerializationError)
PASS rg.string subscriptions wire-level -> 400 InvalidParameter :: wire: 400 InvalidParameter
PASS rg.query where-clause filter :: where filter: totalRecords=1, name=sa7
PASS sentinel.DCR ingest 150 rows -> 204 :: 150 rows ingested to DCR ws-py7/Custom-Logs, HTTP 204
PASS logs.KQL where+order by+take+project :: where/order/take/project: n desc -> [150, 149, 148, 147, 146]
PASS logs.project-not-last envelope columns exact (R177 fix) :: FIXED: project mid-pipeline, envelope columns = ['n', 'msg'], 5 rows
PASS logs.take 100000 capped at 101 :: take 100000 -> 101 rows (cap 101)
PASS logs.malformed pipeline -> 400 BadQuery :: 400 BadQuery surfaced as HttpResponseError

== SUMMARY: 11 pass / 0 fail / 0 error ==
```

## Notes

- KD-22 (Sentinel KQL `project` regex leak) and KD-23 (mixed bare/piped
  `where ... | project`) rows cite this receipt in the v26.10.14 register and
  remain OPEN there; this run re-witnesses both as fixed on this substrate:
  "project-not-last envelope columns exact (R177 fix) :: FIXED" and the mixed
  pipeline passing inside the where+order+take+project probe. Eligible for
  KD-row closure via `scripts/kd_flip.py --apply` once a witness receipt
  postdates the shim (this receipt is that witness candidate).
- The seed claims 150 accounts; wire assertions below it are exact-count
  (150/100/1) — no silent truncation.

## Falsifier replay

```bash
SMALT_ARM_BASE=http://127.0.0.1:<arm> SMALT_EGRESS_BASE=http://127.0.0.1:<egress> \
  test/sdk-python/.venv-rg/bin/python test/sdk-python/py_resourcegraph_monitor.py
# expect: 11 pass / 0 fail / 0 error
```
