#!/usr/bin/env python3
"""PY-7 lane: real azure-mgmt-resourcegraph + azure-monitor-query SDK probes
against the smalt substrate (ARM/STS on :9443 http, egress on :8443 http).

Auth: client_credentials against the substrate STS (any client_id/secret),
mirroring the ARM gateway's issue_token contract (HS256, aud
https://management.azure.com). A tiny custom TokenCredential feeds both
management-plane and monitor clients.

Contract targets (from test/data_plane/audit_planes_test.exs + lib):
  ResourceGraph:
    - POST /providers/Microsoft.RealGraph...
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from azure.core.credentials import AccessToken
from azure.core.exceptions import HttpResponseError
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions
from azure.monitor.query import LogsQueryClient, LogsQueryStatus

ARM = "http://127.0.0.1:9443"
EGRESS = "http://127.0.0.1:8443"
SUB = "sub-py7"
RG_API = "2022-10-01"
DCR = f"ws-py7-{int(time.time())}"
STREAM = "Custom-Logs"

results = []


def probe(name, fn):
    try:
        detail = fn()
        results.append((name, "PASS", detail or ""))
        print(f"PASS {name} :: {detail or ''}", flush=True)
    except AssertionError as e:
        results.append((name, "FAIL", str(e)))
        print(f"FAIL {name} :: {e}", flush=True)
    except Exception as e:
        results.append((name, "ERROR", f"{type(e).__name__}: {e}"))
        print(f"ERROR {name} :: {type(e).__name__}: {e}", flush=True)


class StsCredential:
    """TokenCredential that mints/refreshes a Bearer from the substrate STS."""

    def __init__(self, tenant="py-tenant"):
        self._tenant = tenant
        self._tok = None

    def get_token(self, *scopes, **kwargs):
        now = time.time()
        if self._tok is None or self._tok.expires_on - now < 60:
            data = urllib.parse.urlencode({
                "grant_type": "client_credentials",
                "client_id": "py7-lane",
                "client_secret": "py7-secret",
            }).encode()
            req = urllib.request.Request(
                f"{ARM}/{self._tenant}/oauth2/v2.0/token",
                data=data, method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"})
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.loads(r.read())
            self._tok = AccessToken(body["access_token"], now + body["expires_in"])
        return self._tok


def http(method, url, body=None, headers=None):
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, (json.loads(r.read()) if r.read and r.length else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode("utf-8", "replace")


CRED = StsCredential()


def auth_headers():
    tok = CRED.get_token("https://management.azure.com")
    return {"Authorization": f"Bearer {tok.token}"}


# ---------------------------------------------------------------------------
# Seeding: 150 storage accounts in one RG under SUB via ARM PUT
# ---------------------------------------------------------------------------

def seed_resources():
    h = auth_headers()
    made = 0
    for i in range(1, 151):
        url = (f"{ARM}/subscriptions/{SUB}/resourceGroups/pyrg/providers/"
               f"Microsoft.Storage/storageAccounts/sa{i}?api-version=2021-04-01")
        st, body = http("PUT", url,
                        {"location": "eastus", "properties": {"skuName": "Standard_LRS"}}, h)
        assert st in (201, 200, 202), f"seed PUT sa{i} -> {st}: {body}"
        made += 1
    return made


# ---------------------------------------------------------------------------
# Resource Graph probes
# ---------------------------------------------------------------------------

def rg_client():
    return ResourceGraphClient(credential=CRED, base_url=EGRESS, api_version="2022-10-01")


def p01_query_top():
    def run():
        client = rg_client()
        req = QueryRequest(subscriptions=[SUB],
                           query="project id, name, type",
                           options=QueryRequestOptions(top=150))
        resp = client.resources(req, enforce_https=False)
        assert resp.total_records == 150, f"totalRecords={resp.total_records}"
        assert resp.count == 150, f"count={resp.count}"
        # SDK types result_truncated as a str enum ("true"/"false"); accept the
        # wire boolean form too (smalt sends JSON false, real Azure API spec
        # v2022-10-01 declares string enum).
        assert str(resp.result_truncated).lower() != "true", resp.result_truncated
        assert len(resp.data) == 150
        return f"count=150 totalRecords=150 resultTruncated=False"
    return probe("rg.query $top=150 (full page, no truncation)", run)


def p02_pagination():
    def run():
        client = rg_client()
        names, page, token = [], 0, None
        while True:
            page += 1
            opts = QueryRequestOptions(top=50)
            if token:
                opts.skip_token = token
            req = QueryRequest(subscriptions=[SUB], query="project name",
                               options=opts)
            resp = client.resources(req, enforce_https=False)
            page_names = [r["name"] for r in resp.data]
            assert page_names, f"empty page {page} mid-walk"
            names.extend(page_names)
            token = resp.skip_token
            if not token:
                break
            assert page < 20, "pagination did not terminate"
        assert len(names) == 150, f"got {len(names)} rows across {page} pages"
        assert len(set(names)) == 150, "duplicate names across pages"
        return f"{page} pages x<=50, 150 rows, no dupes"
    return probe("rg.skipToken pagination no dupes, terminates", run)


def p03_default_top():
    def run():
        client = rg_client()
        req = QueryRequest(subscriptions=[SUB], query="project name")
        resp = client.resources(req, enforce_https=False)
        assert resp.count == 100, f"count={resp.count}"
        assert resp.total_records == 150, f"totalRecords={resp.total_records}"
        assert resp.skip_token, "expected $skipToken at default $top"
        return f"default $top: count=100 totalRecords=150 skipToken present"
    return probe("rg.default $top=100 + skipToken present", run)


def p04_string_subscriptions():
    def run():
        client = rg_client()
        # Typed-400 probe: a bare string subscriptions must be refused with
        # InvalidParameter, never 500, never silent all-resources.
        req = QueryRequest(subscriptions=SUB, query="project name")
        try:
            client.resources(req, enforce_https=False)
        except Exception as e:
            # Typed client refuses a bare string before the wire (SerializationError):
            # a client-side guard, so the server's typed 400 is only reachable raw.
            assert type(e).__name__ == "SerializationError", f"{type(e).__name__}: {e}"
            return "typed client refuses str subscriptions client-side (SerializationError)"
        raise AssertionError("string subscriptions was accepted (expected client-side refusal)")
    return probe("rg.string subscriptions -> 400 InvalidParameter", run)


def p04b_string_subs_wire():
    def run():
        # Wire-level fence probe (SDK types forbid a bare string, so this
        # exercises the server-side typed 400 directly).
        h = auth_headers()
        st, body = http("POST",
                        f"{EGRESS}/providers/Microsoft.ResourceGraph/resources"
                        f"?api-version={RG_API}",
                        {"subscriptions": SUB, "query": "project name"}, h)
        assert st == 400, f"wire string subscriptions -> {st}: {body}"
        code = body["error"]["code"]
        assert code == "InvalidParameter", f"code={code}"
        return "wire: 400 InvalidParameter"
    return probe("rg.string subscriptions wire-level -> 400 InvalidParameter", run)


def p05_query_filter():
    def run():
        client = rg_client()
        req = QueryRequest(subscriptions=[SUB],
                           query="where name == 'sa7'")
        resp = client.resources(req, enforce_https=False)
        assert resp.total_records == 1, f"totalRecords={resp.total_records}"
        assert resp.data[0]["name"] == "sa7"
        return "where filter: totalRecords=1, name=sa7"
    return probe("rg.query where-clause filter", run)


# ---------------------------------------------------------------------------
# Sentinel / Log Analytics probes
# ---------------------------------------------------------------------------

def ingest(rows):
    h = auth_headers()
    url = (f"{EGRESS}/dataCollectionRules/{DCR}/streams/{STREAM}"
           f"?api-version=2023-01-01")
    st, body = http("POST", url, rows, h)
    assert st == 204, f"ingest -> {st}: {body}"
    return st


def logs_client():
    return LogsQueryClient(endpoint=EGRESS, credential=CRED)


def p10_dcr_ingest():
    def run():
        rows = [{"msg": f"row-{i}", "n": i} for i in range(1, 151)]
        st = ingest(rows)
        assert st == 204
        return "150 rows ingested to DCR ws-py7/Custom-Logs, HTTP 204"
    return probe("sentinel.DCR ingest 150 rows -> 204", run)


def p20_kql_pipeline():
    def run():
        client = logs_client()
        # project LAST: the envelope column extraction is correct in this form.
        q = ("Custom-Logs | where n >= 145 | order by n desc | take 5 "
             "| project n, msg")
        res = client.query_workspace(DCR, q, timespan=None, enforce_https=False)
        assert res.status == LogsQueryStatus.SUCCESS, res.status
        table = res.tables[0]
        cols = [c if isinstance(c, str) else c.name for c in table.columns]
        assert cols == ["n", "msg"], f"cols={cols}"
        ns = [int(row[0]) for row in table.rows]
        assert ns == [150, 149, 148, 147, 146], f"got {ns}"
        return f"where/order/take/project: n desc -> {ns}"
    return probe("logs.KQL where+order by+take+project", run)


def p20b_project_not_last_divergence():
    def run():
        # DIVERGENCE PROBE (evidence): project NOT last. The KQL engine executes
        # take correctly (5 rows), but the PrimaryResult envelope column list is
        # extracted with regex \\bproject\\s+(.+)$ that runs to end-of-string,
        # so a stage after project leaks into the column names.
        client = logs_client()
        q = "Custom-Logs | project n, msg | take 5"
        res = client.query_workspace(DCR, q, timespan=None, enforce_https=False)
        table = res.tables[0]
        cols = [c if isinstance(c, str) else c.name for c in table.columns]
        leaks = [c for c in cols if "|" in str(c)]
        assert leaks, f"expected column leak, got cols={cols}"
        assert len(table.rows) == 5, f"rows={len(table.rows)} (take did execute)"
        return (f"DIVERGENCE: take executed (5 rows) but envelope columns = {cols}; "
                "real Log Analytics parses columns from the AST")
    return probe("logs.project-not-last envelope column leak (documented divergence)", run)


def p21_take_cap():
    def run():
        client = logs_client()
        res = client.query_workspace(DCR, "Custom-Logs | take 100000", timespan=None, enforce_https=False)
        table = res.tables[0]
        assert len(table.rows) == 101, f"rows={len(table.rows)}"
        return f"take 100000 -> {len(table.rows)} rows (cap 101)"
    return probe("logs.take 100000 capped at 101", run)


def p22_partial_error_badquery():
    def run():
        client = logs_client()
        try:
            client.query_workspace(DCR, "Custom-Logs | where bogus ==", timespan=None, enforce_https=False)
        except HttpResponseError as e:
            code = getattr(getattr(e, "error", None), "code", None)
            assert e.status_code == 400, f"status={e.status_code}"
            assert code == "BadQuery", f"code={code}"
            return "400 BadQuery surfaced as HttpResponseError"
        raise AssertionError("malformed pipeline accepted (expected 400 BadQuery)")
    return probe("logs.malformed pipeline -> 400 BadQuery", run)


def main():
    print("== PY-7 ResourceGraph + Log Analytics (Sentinel) real-SDK probes ==",
          flush=True)
    made = seed_resources()
    print(f"[seed] {made} storage accounts created under {SUB}", flush=True)

    p01_query_top()
    p02_pagination()
    p03_default_top()
    p04_string_subscriptions()
    p04b_string_subs_wire()
    p05_query_filter()

    p10_dcr_ingest()
    p20_kql_pipeline()
    p20b_project_not_last_divergence()
    p21_take_cap()
    p22_partial_error_badquery()

    n_pass = sum(1 for _, s, _ in results if s == "PASS")
    n_fail = sum(1 for _, s, _ in results if s == "FAIL")
    n_err = sum(1 for _, s, _ in results if s == "ERROR")
    print(f"\n== SUMMARY: {n_pass} pass / {n_fail} fail / {n_err} error "
          f"==", flush=True)
    for name, status, detail in results:
        print(f"  {status} {name} :: {detail}", flush=True)
    return 0 if n_fail == 0 and n_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
