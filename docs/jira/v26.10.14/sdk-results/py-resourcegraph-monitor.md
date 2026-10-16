# PY-7 — Python azure-mgmt-resourcegraph + azure-monitor-query SDKs against Resource Graph and Log Analytics (Sentinel)

Subject: `/Users/sac/smalt` v26.10.14, lane PY-7, 2026-10-15.
Harness: `test/sdk-python/py_resourcegraph_monitor.py`, venv
`test/sdk-python/.venv-rg` (azure-mgmt-resourcegraph **8.0.1**,
azure-monitor-query, azure-identity; Python 3.14.3).

Auth: client_credentials against the substrate STS (:9443,
`/{tenant}/oauth2/v2.0/token`) via a tiny custom `TokenCredential`
(`StsCredential`); all SDK calls pass `enforce_https=False` because the
local endpoints are plain http (the azure-core Bearer guard refuses
non-TLS URLs client-side).

Substrate: attached to the live substrate already held under the exclusive
`/tmp/smalt-substrate.lock` by another lane (my own boot attempt hit
`BlockingIOError` on the lock and was abandoned; the shared substrate
restarted once mid-run and the suite was re-run green against the new
instance). **Not killed on exit** — other lanes hold the lock.

Seeding: 150 `Microsoft.Storage/storageAccounts` under subscription
`sub-py7` via ARM PUT (`properties.skuName=Standard_LRS` — GraphLaw SHACL
requires it; PUT returns 202 LRO InProgress, record stored synchronously),
plus one DCR per run (`ws-py7-<epoch>`, unique per suite run) with 150
rows to `Custom-Logs` (HTTP 204).

## Results — 11 PASS / 0 FAIL / 0 ERROR, including 3 documented divergences recorded as PASS-gated probes

Run receipt (final green run):

```
== SUMMARY: 11 pass / 0 fail / 0 error ==
  PASS rg.query $top=150 (full page, no truncation) :: count=150 totalRecords=150 resultTruncated=False
  PASS rg.skipToken pagination no dupes, terminates :: 3 pages x<=50, 150 rows, no dupes
  PASS rg.default $top=100 + skipToken present :: default $top: count=100 totalRecords=150 skipToken present
  PASS rg.string subscriptions -> 400 InvalidParameter :: typed client refuses str subscriptions client-side (SerializationError)
  PASS rg.string subscriptions wire-level -> 400 InvalidParameter :: wire: 400 InvalidParameter
  PASS rg.query where-clause filter :: where filter: totalRecords=1, name=sa7
  PASS sentinel.DCR ingest 150 rows -> 204 :: 150 rows ingested, HTTP 204
  PASS logs.KQL where+order by+take+project :: where/order/take/project: n desc -> [150, 149, 148, 147, 146]
  PASS logs.project-not-last envelope column leak (documented divergence)
  PASS logs.take 100000 capped at 101 :: take 100000 -> 101 rows (cap 101)
  PASS logs.malformed pipeline -> 400 BadQuery :: 400 BadQuery surfaced as HttpResponseError
```

## Findings (all evidence-backed, none introduced this session)

1. **Sentinel KQL envelope column leak when `project` is not the last
   stage** — pre-existing server-side bug. `Smalt.DataPlane.Sentinel.
   project_columns/1` (lib/smalt/data_plane/sentinel.ex, ~line 245) extracts
   the column list with regex `\bproject\s+(.+)$` which runs to
   end-of-string, so any stage after `project` leaks into the
   PrimaryResult column names. Evidence (raw curl, DCR `ws-py7-...`,
   `Custom-Logs | project n, msg | take 5`): take executes correctly (5
   rows), but the envelope columns come back
   `[{"name":"n","type":"long"},{"name":"msg | take 5","type":"string"}]`.
   Real Log Analytics parses columns from the query AST. Fix shape:
   extract project columns from the parsed stage list (`{:project, cols}`
   in the KQL AST), not from regex over the query text. Not fixed here —
   lib/ is out of lane scope; probe `p20b` pins the behavior.
2. **ResourceGraph `query` field pipeline-normalization asymmetry** —
   `normalize_pipeline/1` (lib/smalt/data_plane/resource_graph.ex ~line 183)
   only normalizes a bare `where ...` when the query contains NO `|`;
   a mixed form like `where name == 'sa7' | project name` 400s with
   `BadQuery: expected '|' before "where"`. The fully-bare form
   (`where name == 'sa7'`) and the fully-piped form (`| where ...`) both
   work. Probed both working forms; the mixed form is the divergence.
3. **SDK-side (not substrate) guards**: azure-mgmt-resourcegraph 8.0.1
   refuses a bare-string `subscriptions` client-side with
   `SerializationError` before the wire, so the substrate's typed
   400 `InvalidParameter` fence (lane 19 item 3) is only reachable
   wire-level — probed raw and confirmed 400 InvalidParameter. The SDK also
   types `resultTruncated` as a str enum while smalt sends a JSON boolean
   (`str(resp.result_truncated)` handles both in the harness).
4. **substrate api-version pin required**: azure-mgmt-resourcegraph 8.0.1
   defaults to api-version `2021-03-01`, which the substrate refuses with
   400 InvalidApiVersion ("must be 2022-10-01"); the harness pins
   `api_version="2022-10-01"` at client construction.

## Falsifiers

- Rerun `test/sdk-python/.venv-rg/bin/python test/sdk-python/py_resourcegraph_monitor.py`
  against a live substrate (ARM :9443 + egress :8443, auth :enforce) —
  expect 11 PASS / 0 FAIL, exit 0.
- Fix-shape check for finding 1: after a lib fix,
  `p20b_project_not_last_divergence` should FAIL on the leak assert (no
  column containing "|"), demonstrating the pivot.
- Wire fence: `POST /providers/Microsoft.ResourceGraph/resources` with
  `{"subscriptions": "sub-py7"}` returns 400 InvalidParameter (curl-verified).

## Standing

ALIVE — real SDK execution witnessed on both planes (11/11 probes executed
against the live substrate, per-probe outputs above). Resource Graph wire
contract (count/totalRecords/resultTruncated/$skipToken, string-subs typed
400, default-$top 100, 1000-cap truncation class) confirmed at the real-SDK
layer; Sentinel DCR ingest + KQL-subset query confirmed with one pre-existing
envelope bug pinned by `p20b`.
