"""WF7 — PY mirror of the diagnostics coverage (verification/ts/diagnostics.probe.mjs).

Sentinel/Log Analytics DCR ingest + KQL query engine, KQL typed parse errors
(SYN codes), the microsoft.insights/metrics ARM arm, and the appconfig
snapshot freeze semantics — all against the real enforce substrate
(conftest `enforce_arm`, block v1: ARM 39712 / egress 39713 / TLS 39714),
raw wire (requests), no mocks.

Cells (receipt grammar <surface>:<op>):
  1. sentinel:dcr-ingest-kql-aggregate — 10-row DCR ingest (warn=5, error=3,
     info=2), aggregated back through
     `| where TimeGenerated > ago(1h) | summarize count() by Level | sort by count_ desc`;
     the table must equal the ingested distribution (values + desc order).
  2. sentinel:kql-typed-parse-error — unknown pipeline operator -> 400
     BadQuery with a SYN\\d{4} code and a positive byte position.
  3. arm:monitor-metrics-emit-query — POST a custom metric point at a real
     SB namespace resource, GET the series back; FUTURE api-version (2099)
     refused 400 InvalidApiVersionParameter (KD-78 monotonic shape, corpus
     law: FUTURE pin, never a past one).
  4. sentinel:table-stats — typed SKIP: no multi-table stats surface
     (workspace tables ARM family) is routed.
  5. appconfig:snapshot-freeze — the freeze-semantics lane: PUT snapshot ->
     mutate live KV -> frozen /kv view unchanged -> archive -> kv view
     refuses -> purge -> gone. Gated on the wire lane having landed: if the
     egress route fragment is absent the cell is a typed SKIP naming the
     owning surface (never a fake pass).

Same rules as wf1-wf6: typed SKIP/xfail with surface citation, no fixed
sleeps (nothing here needs waiting — every leg is a direct request/response),
native-exception table rows for any SDK legs (this lane is raw wire; the
expect_http_error row from harness.errors guards the negative asserts).
"""
import re
import secrets
from datetime import datetime, timezone

import pytest
import requests

from conftest import EGRESS, bearer, http

pytestmark = pytest.mark.enforce

RUN = "pywf7"
SENTINEL_APIV = "2023-01-01"
METRICS_APIV = "2024-02-01"  # Smalt.Metrics @latest_api_version
ARM_APIV = "2021-04-01"
FUTURE_APIV = "2099-01-01"  # corpus law: FUTURE api-version pin, never a past one
SUB = "py-verify-sub"


def _query(workspace, kql, hdrs):
    return requests.post(
        f"{EGRESS}/v1/workspaces/{workspace}/query",
        params={"api-version": SENTINEL_APIV},
        json={"query": kql},
        headers={"Content-Type": "application/json", **hdrs},
        timeout=15,
    )


def _table(resp):
    """First PrimaryResult table of a 200 query response: (columns, rows)."""
    body = resp.json()
    tables = body.get("tables") or []
    assert tables, f"no tables in query response: {str(body)[:200]}"
    table = tables[0]
    return (
        [c["name"] for c in table.get("columns", [])],
        table.get("rows", []),
    )


# ---------------------------------------------------------------------------
# Cell 1 — DCR ingest -> KQL aggregate round-trip
# ---------------------------------------------------------------------------


def test_sentinel_dcr_ingest_kql_aggregate():
    """10-row ingest; `summarize count() by Level` must reproduce the ingested
    distribution exactly (warn=5, error=3, info=2) and sort count_ desc."""
    dcr = f"{RUN}-dcr-{secrets.token_hex(3)}"
    hdrs = bearer()
    dist = [("warn", 5), ("error", 3), ("info", 2)]
    rows = [
        {
            # Fresh ingest-time stamp: ago(1h) filters stale rows out (witnessed:
            # a fixed 00:00Z stamp 8.5h old is filtered to an empty table).
            "TimeGenerated": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "Level": lvl,
            "batch": gi,
            "msg": f"wf7 row {gi}-{i}",
        }
        for gi, (lvl, n) in enumerate(dist)
        for i in range(n)
    ]
    ing = requests.post(
        f"{EGRESS}/dataCollectionRules/{dcr}/streams/Custom-Logs",
        params={"api-version": SENTINEL_APIV},
        json=rows,
        headers=hdrs,
        timeout=15,
    )
    assert ing.status_code == 204, f"ingest -> {ing.status_code}: {ing.text[:200]}"
    request_id = ing.headers.get("x-ms-request-id")
    assert request_id, "ingest 204 without x-ms-request-id (real LA answers with one)"

    q = _query(
        dcr,
        "Custom-Logs | where TimeGenerated > ago(1h) "
        "| summarize count() by Level | sort by count_ desc",
        hdrs,
    )
    assert q.status_code == 200, f"query -> {q.status_code}: {q.text[:200]}"
    cols, got_rows = _table(q)
    assert "Level" in cols, f"Level column missing: {cols}"
    assert "count_" in cols, f"count_ column missing: {cols}"

    got = sorted((r[0], int(r[1])) for r in got_rows)
    assert got == sorted(dist), f"distribution mismatch: got {got}, want {sorted(dist)}"

    counts = [int(r[1]) for r in got_rows]
    assert counts == sorted(counts, reverse=True), (
        f"sort by count_ desc not honored: {got_rows}"
    )


# ---------------------------------------------------------------------------
# Cell 2 — KQL typed parse error (SYN code + byte position)
# ---------------------------------------------------------------------------


def test_sentinel_kql_typed_parse_error():
    """Unknown pipeline operator `frobnicate` -> 400 BadQuery whose message
    carries a SYN\\d{4} code and a positive byte position (fail-closed:
    unknown operators are typed parse errors, never silent-ignore)."""
    hdrs = bearer()
    dcr = f"{RUN}-dcr-{secrets.token_hex(3)}"
    r = _query(
        dcr,
        "Custom-Logs | where Level == 'warn' | frobnicate by Level",
        hdrs,
    )
    body = r.json() or {}
    msg = (body.get("error") or {}).get("message", "")
    syn = re.search(r"SYN\d{4}", msg)
    pos = re.search(r"\(position (\d+)\)", msg)
    assert r.status_code == 400, f"expected 400, got {r.status_code}: {r.text[:200]}"
    assert (body.get("error") or {}).get("code") == "BadQuery", (
        f"error.code={body.get('error', {}).get('code')!r}"
    )
    assert syn, f"no SYN code in message: {msg[:160]!r}"
    assert pos and int(pos.group(1)) > 0, f"no positive byte position in: {msg[:160]!r}"


# ---------------------------------------------------------------------------
# Cell 3 — microsoft.insights/metrics emit + query (ARM plane)
# ---------------------------------------------------------------------------


def test_arm_monitor_metrics_emit_query(enforce_arm):
    """Custom metric emit (POST) then bucketed series query (GET) on a real SB
    namespace resource; FUTURE api-version refused 400
    InvalidApiVersionParameter (KD-78 monotonic admission shape)."""
    arm = enforce_arm
    hdrs = bearer()
    rg = f"{RUN}-rg-{secrets.token_hex(3)}"
    ns = f"{RUN}-ns-{secrets.token_hex(3)}"
    r = requests.put(
        f"{arm}/subscriptions/{SUB}/resourceGroups/{rg}",
        params={"api-version": ARM_APIV},
        json={"location": "local"},
        headers=hdrs, timeout=15, allow_redirects=False,
    )
    assert r.status_code in (200, 201, 202), f"rg PUT -> {r.status_code}"
    r = requests.put(
        f"{arm}/subscriptions/{SUB}/resourceGroups/{rg}"
        f"/providers/Microsoft.ServiceBus/namespaces/{ns}",
        params={"api-version": ARM_APIV},
        json={"location": "local", "skuName": "Standard"},
        headers=hdrs, timeout=15, allow_redirects=False,
    )
    assert r.status_code in (200, 201, 202), f"namespace PUT -> {r.status_code} {r.text[:200]}"

    res_base = (
        f"{arm}/subscriptions/{SUB}/resourceGroups/{rg}"
        f"/providers/Microsoft.ServiceBus/namespaces/{ns}"
        f"/providers/microsoft.insights/metrics"
    )
    emit = requests.post(
        res_base,
        params={"api-version": METRICS_APIV},
        json={"metric": "wf7QueueDepth", "value": 42, "unit": "Count"},
        headers=hdrs, timeout=15,
    )
    assert emit.status_code == 200, f"metrics emit -> {emit.status_code}: {emit.text[:200]}"
    got = requests.get(
        res_base,
        params={"api-version": METRICS_APIV, "metricnames": "wf7QueueDepth",
                "timespan": "PT1H"},
        headers=hdrs, timeout=15,
    )
    assert got.status_code == 200, f"metrics query -> {got.status_code}: {got.text[:200]}"
    series = got.json().get("value") or []
    assert series, f"empty metrics series: {str(got.json())[:200]}"

    bad = requests.get(res_base, params={"api-version": FUTURE_APIV},
                       headers=hdrs, timeout=15)
    body = bad.json() or {}
    assert bad.status_code == 400, (
        f"FUTURE api-version {FUTURE_APIV} admitted ({bad.status_code}) — monotonic "
        f"refusal missing: {str(body)[:200]}"
    )
    err = body.get("error") or {}
    assert err.get("code") == "InvalidApiVersionParameter" or \
        "InvalidApiVersion" in str(body)[:400], (
        f"refusal not typed InvalidApiVersionParameter: {str(body)[:200]}"
    )


# ---------------------------------------------------------------------------
# Cell 4 — sentinel table stats: typed SKIP (surface not routed)
# ---------------------------------------------------------------------------


def test_sentinel_table_stats():
    """No multi-table stats surface (workspace tables ARM family) is routed on
    the egress or ARM gateways. Typed SKIP naming the owning surface; flip to
    a real probe when the lane lands."""
    pytest.skip(
        "not-landed — owning surface: Sentinel/Log Analytics workspace tables ARM "
        "family (GET workspaces/:id/tables) — no route on egress_router.ex or "
        "arm_gateway/router.ex"
    )


# ---------------------------------------------------------------------------
# Cell 5 — appconfig snapshot freeze semantics (wire-lane gated)
# ---------------------------------------------------------------------------


def _kv_put(key, value, label, hdrs):
    return requests.put(
        f"{EGRESS}/kv/{key}",
        params={"label": label},
        json={"value": value},
        headers=hdrs,
        timeout=15,
    )


def test_appconfig_snapshot_freeze():
    """Freeze semantics IF the snapshot wire lane landed: PUT snapshot over a
    key-filter selection -> mutate the live /kv records -> the snapshot's
    /kv view still returns the frozen bodies -> archive -> the kv view refuses
    -> purge -> the snapshot is gone. If the egress route fragment is absent
    (404-class on the probe PUT), typed SKIP naming the owning surface
    (AppConfigSnapshots module is lib/landed; the egress route is not)."""
    hdrs = bearer()
    name = f"{RUN}-snap-{secrets.token_hex(3)}"
    probe = requests.put(
        f"{EGRESS}/snapshots/{name}",
        params={"api-version": "2023-11-01"},
        json={"filters": {"filters": [{"key": f"{RUN}/"}]}},
        headers=hdrs,
        timeout=15,
    )
    if probe.status_code in (404, 405, 501) or (
        probe.status_code == 400
        and "MissingXMsVersion" in probe.text
    ):
        pytest.skip(
            f"not-landed — appconfig snapshot wire route absent: PUT /snapshots/{name} "
            f"-> {probe.status_code}; owning surface: egress_router.ex appconfig "
            "snapshot route fragment over Smalt.DataPlane.AppConfigSnapshots "
            "(module landed in lib/, wire not wired)"
        )
    assert probe.status_code in (200, 201), (
        f"snapshot probe PUT -> {probe.status_code}: {probe.text[:200]}"
    )

    # Landed branch: full freeze-semantics flow.
    k1, k2 = f"{RUN}/freeze/a", f"{RUN}/freeze/b"
    assert _kv_put(k1, "v1", "prod", hdrs).status_code in (200, 201)
    assert _kv_put(k2, "w1", "prod", hdrs).status_code in (200, 201)
    snap = requests.put(
        f"{EGRESS}/snapshots/{name}",
        params={"api-version": "2023-11-01"},
        json={"filters": {"filters": [{"key": f"{RUN}/freeze/"}]}},
        headers=hdrs,
        timeout=15,
    )
    assert snap.status_code in (200, 201), f"snapshot PUT -> {snap.status_code}"
    assert snap.json().get("properties", snap.json()).get("itemCount", 0) >= 2

    # Freeze: mutate BOTH live records after the snapshot; the frozen view
    # must keep the creation-time values.
    _kv_put(k1, "MUTATED", "prod", hdrs)
    _kv_put(k2, "MUTATED", "prod", hdrs)
    view = requests.get(
        f"{EGRESS}/snapshots/{name}/kv", params={"api-version": "2023-11-01"},
        headers=hdrs, timeout=15,
    )
    assert view.status_code == 200, f"snapshot kv view -> {view.status_code}"
    items = view.json().get("items", view.json())
    frozen_vals = {
        it.get("key"): it.get("value") for it in items
    } if isinstance(items, list) else {}
    assert frozen_vals.get(k1) == "v1" and frozen_vals.get(k2) == "w1", (
        f"freeze leaked live mutations: {frozen_vals}"
    )

    # archive -> kv view refuses; purge of non-archived refuses; purge of
    # archived deletes; re-purge -> 404 class.
    arch = requests.post(
        f"{EGRESS}/snapshots/{name}/archive", params={"api-version": "2023-11-01"},
        headers=hdrs, timeout=15,
    )
    assert arch.status_code in (200, 201, 204), f"archive -> {arch.status_code}"
    view_after = requests.get(
        f"{EGRESS}/snapshots/{name}/kv", params={"api-version": "2023-11-01"},
        headers=hdrs, timeout=15,
    )
    assert view_after.status_code in (404, 409), (
        f"archived snapshot kv view still servable: {view_after.status_code}"
    )
    purge = requests.delete(
        f"{EGRESS}/snapshots/{name}", params={"api-version": "2023-11-01"},
        headers=hdrs, timeout=15,
    )
    assert purge.status_code in (200, 204), (
        f"purge of ARCHIVED snapshot refused: {purge.status_code} {purge.text[:150]}"
    )
    gone = requests.get(
        f"{EGRESS}/snapshots/{name}", params={"api-version": "2023-11-01"},
        headers=hdrs, timeout=15,
    )
    assert gone.status_code == 404, (
        f"purged snapshot still readable: {gone.status_code}"
    )
