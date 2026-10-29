"""EXPL12-B — monitor group court (real wire, no mocks).

Faces witnessed: microsoft.insights/metrics (live accumulator timeseries from
REAL requests), the OCEL NDJSON sink tail, /metadata/endpoints. No invented
faces: activity-log/alerts have no ARM route and get no command.
"""
import json
import pathlib
import time
import uuid

import httpx
import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"m{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("SMALT_ARM", conftest.ANON_ARM)
    monkeypatch.setenv("SMALT_EGRESS", conftest.ANON_EGRESS)


def _hit_resource_arm_path() -> str:
    """Make a REAL ARM request carrying a 5-segment resource path so the
    Monitor.Metrics accumulator records a Requests row for it. The path has
    no route (404) but the bandit telemetry stop event still fires."""
    res = (f"subscriptions/smalt-sub/resourceGroups/{UNIQ}"
           f"/providers/Microsoft.Foo/bars/{UNIQ}")
    httpx.get(f"{conftest.ANON_ARM}/{res}", verify=False, timeout=15.0)
    return res


def test_metrics_live_custom_metric_series():
    # Real resource + real custom-metric emit (POST microsoft.insights/metrics)
    # -> the CLI face surfaces the live series.
    tok = httpx.post(f"{conftest.ANON_ARM}/oauth2/v2.0/token",
                     data={"grant_type": "client_credentials",
                           "client_id": "expl12b", "client_secret": "x"},
                     verify=False, timeout=15.0).json()["access_token"]
    hdr = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    res = f"subscriptions/smalt-sub/resourceGroups/{UNIQ}/providers/Microsoft.Storage/storageAccounts/{UNIQ}"
    st = httpx.put(f"{conftest.ANON_ARM}/{res}?api-version=2021-04-01",
                         json={"location": "eastus",
                               "properties": {"skuName": "Standard_LRS"}},
                         headers=hdr, verify=False, timeout=15.0)
    assert st.status_code in (200, 201, 202), st.text
    em = httpx.post(
        f"{conftest.ANON_ARM}/{res}/providers/microsoft.insights/metrics?api-version=2024-02-01",
        json={"metric": "Expl12bMetric", "value": 42},
        headers=hdr, verify=False, timeout=15.0)
    assert em.status_code == 200, em.text

    rg = UNIQ
    r = runner.invoke(app, ["monitor", "metrics", rg, "Microsoft.Storage",
                            "storageAccounts", UNIQ, "--metric",
                            "Expl12bMetric", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"series_count": 1' in r.output
    assert "Expl12bMetric" in r.output
    # A real datapoint rides the dense series (total 42 from the emit).
    assert '"total": 42' in r.output


def test_metrics_unknown_resource_empty_envelope():
    # Real-Azure semantics: unknown resource 200s with an EMPTY value[].
    r = runner.invoke(app, ["monitor", "metrics", f"{UNIQ}-nope", "X.Y",
                            "zs", f"{UNIQ}-n", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"series_count": 0' in r.output


def test_ocel_tail_reads_real_sink():
    # Real substrate sink shape (Smalt.Telemetry.OcelNdjson): ONE event object
    # per line with UNPREFIXED id/type/time keys. The old premise (wrapped
    # {"ocel:events": [...]} with ocel:-prefixed per-event keys) was the
    # BK-MON-3 defect — the CLI's own json face proved the real shape.
    sink = conftest_tmp_sink()
    events = []
    for i in range(3):
        events.append(json.dumps({
            "id": f"e{i}-{UNIQ}",
            "type": "Test.Type",
            "time": "2026-10-22T00:00:0%dZ" % i,
            "attributes": {"i": i},
        }))
    sink.write_text("\n".join(events) + "\n")

    r = runner.invoke(app, ["monitor", "ocel-tail", "-n", "2", "--file",
                            str(sink), "-o", "json"])
    assert r.exit_code == 0, r.output
    assert f"e2-{UNIQ}" in r.output
    assert f"e0-{UNIQ}" not in r.output  # only the last 2


def test_ocel_tail_table_renders_real_values():
    # BK-MON-3 court leg: the table face renders REAL id/type/time values
    # from the unprefixed per-event shape (every field was "?" before).
    sink = conftest_tmp_sink()
    sink.write_text("\n".join(
        json.dumps({"id": f"t{i}-{UNIQ}", "type": "Repair.Lane",
                    "time": f"2026-10-22T0{i}:00:00Z"})
        for i in range(2)
    ) + "\n")

    r = runner.invoke(app, ["monitor", "ocel-tail", "--file", str(sink)])
    assert r.exit_code == 0, r.output
    assert f"t0-{UNIQ}" in r.output
    assert f"t1-{UNIQ}" in r.output
    assert "Repair.Lane" in r.output
    assert "?" not in r.output


def test_ocel_tail_default_sink_repo_anchored():
    # BK-MON-4: the default sink path resolves from the repo root, not the
    # cwd — run from smalt-cli/ with NO --file and NO SMALT_OCEL_FILE: the
    # real repo-root sink (tmp/ocel/events.ndjson) is still found and
    # rendered. Read-only witness against the real sink.
    import os
    import subprocess
    import sys

    repo = pathlib.Path(__file__).resolve().parents[1]
    env = {k: v for k, v in os.environ.items() if k != "SMALT_OCEL_FILE"}
    proc = subprocess.run(
        [sys.executable, "-m", "smalt_cli.cli", "monitor", "ocel-tail",
         "-n", "3", "-o", "json"],
        capture_output=True, text=True, env=env, cwd=str(repo),
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    assert '"id"' in proc.stdout
    assert proc.stdout.count('"id"') <= 3


def test_ocel_tail_wrapped_document_still_parsed():
    # Tolerated legacy shape: a wrapped {"ocel:events": [{"ocel:id": ...}]}
    # document line still renders (dual-face), values surfaced not "?".
    sink = conftest_tmp_sink()
    sink.write_text(json.dumps({
        "ocel:events": [{"ocel:id": f"w-{UNIQ}", "ocel:type": "Wrapped",
                         "ocel:time": "2026-10-22T00:00:00Z"}],
    }) + "\n")

    r = runner.invoke(app, ["monitor", "ocel-tail", "--file", str(sink)])
    assert r.exit_code == 0, r.output
    assert f"w-{UNIQ}" in r.output
    assert "?" not in r.output


def test_ocel_tail_missing_sink_andon():
    r = runner.invoke(app, ["monitor", "ocel-tail", "--file",
                            f"/tmp/{UNIQ}-does-not-exist.ndjson"])
    assert r.exit_code == 1
    assert "ANDON" in r.output


def test_endpoints_discovery_face():
    r = runner.invoke(app, ["monitor", "endpoints", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert "login" in r.output or "token" in r.output


def conftest_tmp_sink():
    import pathlib
    import tempfile
    d = pathlib.Path(tempfile.mkdtemp(prefix="expl12b-ocel-"))
    return d / "events.ndjson"
