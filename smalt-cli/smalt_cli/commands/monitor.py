"""monitor sub-app (EXPL12-B): the honest observability face.

Only faces the substrate genuinely serves:

  - metrics     GET .../providers/microsoft.insights/metrics (ARM 9443) —
                bucketed timeseries for a resource; live Requests/
                RequestDuration from the Smalt.Monitor.Metrics accumulator
                (real :telemetry events). Unknown resource -> the real-Azure
                EMPTY value[] envelope (200, never an error).
  - ocel-tail   last N lines of the OCEL 2.0 NDJSON sink the substrate
                writes (Smalt.Telemetry.OcelNdjson, tmp/ocel/events.ndjson).
  - endpoints   GET /metadata/endpoints (ARM bootstrap/discovery face).

Typed honestly: the ARM gateway serves NO activity-log or metric-alerts
route (lib/smalt/monitor/activity_log.ex is a telemetry handler only, never
routed) — so there is no `activity-log` or `alerts` command here. Nothing
invented.
"""
from __future__ import annotations

import json
import os
import pathlib

import typer

from .. import wire

app = typer.Typer(help="Substrate telemetry: metrics, OCEL tail, discovery.")


def _metrics_url(sub: str, rg: str, ns: str, rtype: str, name: str) -> str:
    return (
        f"{wire.arm_endpoint()}/subscriptions/{sub}/resourceGroups/{rg}"
        f"/providers/{ns}/{rtype}/{name}/providers/microsoft.insights/metrics"
    )


@app.command("metrics")
def metrics(
    resource_group: str = typer.Argument(..., help="Resource group."),
    provider_ns: str = typer.Argument(..., help="Provider namespace, e.g. Microsoft.Storage."),
    resource_type: str = typer.Argument(..., help="Resource type, e.g. storageAccounts."),
    resource_name: str = typer.Argument(..., help="Resource name."),
    subscription: str = typer.Option("smalt-sub", "--subscription", "-s"),
    metric: str = typer.Option("", "--metric", help="Metric name (default: Requests)."),
    timespan: str = typer.Option("", "--timespan", help="start/end ISO8601."),
    interval: str = typer.Option("", "--interval", help="PT1M-style interval."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Query Azure Monitor timeseries for a resource (GET microsoft.insights/metrics)."""
    extra = {"api-version": "2024-02-01"}
    if metric:
        extra["metricnames"] = metric
    if timespan:
        extra["timespan"] = timespan
    if interval:
        extra["interval"] = interval
    url = _metrics_url(subscription, resource_group, provider_ns,
                       resource_type, resource_name)
    resp = wire.arm_request("GET", url, params=extra or None)
    if resp.status_code != 200:
        wire.andon(f"monitor metrics refused", status=resp.status_code)
    payload = resp.json()
    series = payload.get("value", [])
    emit_body = {
        "resource": f"/subscriptions/{subscription}/resourceGroups/{resource_group}"
                    f"/providers/{provider_ns}/{resource_type}/{resource_name}",
        "series_count": len(series),
        "value": series,
    }
    wire.emit(emit_body, output, title="monitor metrics")


@app.command("ocel-tail")
def ocel_tail(
    lines: int = typer.Option(20, "--lines", "-n", min=1),
    file: str = typer.Option(
        "", "--file",
        help="OCEL NDJSON sink path (default SMALT_OCEL_FILE or tmp/ocel/events.ndjson).",
    ),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Tail the substrate's OCEL 2.0 NDJSON event sink (last N events)."""
    # BK-MON-4: the default sink is repo-root-anchored (this module lives at
    # <repo>/smalt-cli/smalt_cli/commands/monitor.py), not cwd-relative —
    # running from outside the repo root still finds the real sink.
    default_sink = (
        pathlib.Path(__file__).resolve().parents[3] / "tmp" / "ocel" / "events.ndjson"
    )
    path = pathlib.Path(file or os.environ.get("SMALT_OCEL_FILE") or default_sink)
    if not path.exists():
        wire.andon(f"ocel sink not found: {path}")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            back = min(size, lines * 4096)
            f.seek(size - back)
            chunk = f.read().decode("utf-8", errors="replace")
            all_lines = [ln for ln in chunk.splitlines() if ln.strip()]
            # If we read from mid-file the first line may be partial; drop it
            # unless we started at byte 0.
            if back < size and all_lines:
                all_lines = all_lines[1:]
            tail_lines = all_lines
    except OSError as exc:
        wire.andon(f"ocel sink unreadable: {exc}")
    # -n counts EVENTS, not physical lines: the real sink's wrapped OCEL
    # document lines carry many events each (BK-MON-4 court, real 614k-line
    # sink), so last-N must flatten both faces — bare per-event NDJSON lines
    # AND {"ocel:events": [...]} documents — then take the last N events.
    events: list[dict] = []
    for ln in tail_lines:
        try:
            obj = json.loads(ln)
        except ValueError:
            events.append({"id": "INVALID-JSON", "type": ln[:120], "time": ""})
            continue
        if isinstance(obj, dict) and isinstance(obj.get("ocel:events"), list):
            events.extend(e for e in obj["ocel:events"] if isinstance(e, dict))
        elif isinstance(obj, dict):
            events.append(obj)
        else:
            events.append({"id": "INVALID-LINE", "type": str(obj)[:120], "time": ""})
    tail = events[-lines:]
    if output == "json":
        typer.echo(json.dumps(tail, indent=2, default=str))
        return
    typer.echo(f"# ocel tail: {path} (last {len(tail)} events)")
    for e in tail:
        typer.echo("\t".join([
            str(e.get("id") or e.get("ocel:id", "?")),
            str(e.get("type") or e.get("ocel:type", "?")),
            str(e.get("time") or e.get("ocel:time", "?")),
        ]))


@app.command("endpoints")
def endpoints(
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Fetch the ARM bootstrap/discovery face (GET /metadata/endpoints)."""
    resp = wire.arm_request(
        "GET", f"{wire.arm_endpoint()}/metadata/endpoints")
    if resp.status_code != 200:
        wire.andon("metadata/endpoints refused", status=resp.status_code)
    wire.emit(resp.json(), output, title="metadata endpoints")
