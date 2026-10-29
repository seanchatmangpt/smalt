"""deployment sub-app: resource group create + ARM deployment create.

The deployments face (arm_gateway PUT .../deployments/:name) admits and
records the template but does NOT apply it; materialization is the client's
resource PUTs. `deployment create` therefore PUTs the deployment, then PUTs
each template resource through the ARM registry face, so the resource is
REAL: GET after deploy resolves it (court asserts this).

bicep: `az bicep build` is used when --bicep is given; if the az CLI is
absent, the command types the refusal honestly (ANDON) rather than faking.
"""
from __future__ import annotations

import json
import subprocess

import typer

from .. import wire

app = typer.Typer(help="ARM deployments (control plane :9443).")

_SB = "Microsoft.ServiceBus"


@app.command("group-create")
def group_create(
    name: str = typer.Argument(...),
    location: str = typer.Option("eastus", "--location", "-l"),
    subscription: str = typer.Option("smalt-sub", "--subscription", "-s"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a resource group (PUT /subscriptions/:sub/resourcegroups/:rg)."""
    resp = wire.arm_put(
        f"subscriptions/{subscription}/resourceGroups/{name}",
        {"location": location},
    )
    wire.expect(resp, (200, 201), f"group-create {name}")
    wire.emit({"name": name, "location": location, "status": resp.status_code},
              output, title=f"resource group {name}")


def _template_from_args(template: str | None, bicep: str | None) -> dict:
    if bicep:
        try:
            proc = subprocess.run(
                ["az", "bicep", "build", "--file", bicep, "--stdout"],
                capture_output=True, text=True, timeout=120,
            )
        except FileNotFoundError:
            wire.andon("bicep build requires the az CLI (not on PATH); "
                       "pass ARM JSON via --template instead")
        if proc.returncode != 0:
            wire.andon(f"bicep build failed: {proc.stderr.strip()[:400]}")
        return json.loads(proc.stdout)
    if template:
        try:
            with open(template) as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            wire.andon(f"template unreadable/invalid: {e}")
    wire.andon("deployment create needs --template ARM JSON or --bicep")


def _parse_parameters(param_args: list[str] | None) -> dict:
    """az-parity -p/--parameters: accept a JSON file path, @file, inline JSON,
    or repeatable KEY=VALUE pairs; returns the {key: {"type":..,"value":..}}
    deployment parameter map (unwrapped values kept as-is)."""
    params: dict = {}
    for raw in param_args or []:
        text = raw
        loaded = None
        if raw.startswith("@") or raw.endswith(".json"):
            path = raw.lstrip("@")
            try:
                with open(path) as f:
                    loaded = json.load(f)
            except (OSError, ValueError) as e:
                wire.andon(f"--parameters file unreadable/invalid: {e}")
        elif raw.lstrip().startswith("{"):
            try:
                loaded = json.loads(raw)
            except ValueError as e:
                wire.andon(f"--parameters inline JSON invalid: {e}")
        if isinstance(loaded, dict):
            for k, v in loaded.items():
                params[k] = v.get("value") if isinstance(v, dict) and \
                    set(v) <= {"value", "type"} else v
            continue
        if "=" not in raw:
            wire.andon(f"--parameters entry not KEY=VALUE, @file, or JSON: "
                       f"{raw!r}")
        k, _, v = raw.partition("=")
        params[k.strip()] = v
    return params


def _substitute_parameters(value, params: dict):
    """ARM expression substitution: [parameters('key')] (single or double
    quotes) resolved against the deployment parameter map, recursively over
    lists/dicts. Unknown names are left verbatim (real ARM would template-
    validate; the emulator face is lenient)."""
    if isinstance(value, str):
        for k, v in params.items():
            for q in ("'", '"'):
                value = value.replace(f"[parameters({q}{k}{q})]", _render(v))
        return value
    if isinstance(value, list):
        return [_substitute_parameters(v, params) for v in value]
    if isinstance(value, dict):
        return {k: _substitute_parameters(v, params) for k, v in value.items()}
    return value


def _render(v) -> str:
    return json.dumps(v) if isinstance(v, (dict, list)) else str(v)


def _resource_path(sub: str, rg: str, res: dict) -> str | None:
    """ARM resource path from type+name. Child types (>=3 type segments)
    interleave name segments: type A/B/c + name 'ns/q' -> A/.../B/ns/c/q."""
    rtype = res.get("type") or ""
    name = res.get("name") or ""
    if not rtype or not name:
        return None
    segs = rtype.split("/")
    provider = segs[0]
    rest = segs[1:]
    name_segs = name.split("/")
    parts: list[str] = []
    for i, seg in enumerate(rest):
        parts.append(seg)
        if i < len(name_segs):
            parts.append(name_segs[i])
    return (f"subscriptions/{sub}/resourceGroups/{rg}/providers/"
            + "/".join([provider] + parts))


@app.command("create")
def create(
    name: str = typer.Argument(...),
    resource_group: str = typer.Option("cli-rg", "--resource-group", "-g"),
    subscription: str = typer.Option("smalt-sub", "--subscription", "-s"),
    template: str = typer.Option("", "--template", "-t",
                                 help="ARM template JSON file."),
    bicep: str = typer.Option("", "--bicep", help="Bicep file (az bicep build)."),
    parameters: list[str] = typer.Option(
        [], "--parameters", "-p",
        help="Deployment parameters: @file.json, inline JSON, or repeatable "
             "KEY=VALUE.",
    ),
    mode: str = typer.Option("Incremental", "--mode"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """PUT the deployment, then materialize each template resource."""
    tmpl = _template_from_args(template or None, bicep or None)
    params = _parse_parameters(parameters)
    # Accept the wrapped deployment body shape ({"properties": {"template":
    # {...}}}) by unwrapping, so a properties-wrapped file is not silently
    # read as an empty template.
    if isinstance(tmpl.get("properties"), dict) and \
            isinstance(tmpl["properties"].get("template"), dict):
        tmpl = tmpl["properties"]["template"]
    resources = tmpl.get("resources", [])
    if not isinstance(resources, list):
        # Real ARM refuses a template whose `resources` is not a list; an
        # empty applied-list with exit 0 would be a silent fake pass.
        wire.andon("deployment create: template 'resources' must be a list, "
                   f"got {type(resources).__name__}")
    dep_body = {
        "properties": {"template": tmpl, "parameters": params, "mode": mode}
    }
    resp = wire.arm_put(
        f"subscriptions/{subscription}/resourceGroups/{resource_group}/"
        f"providers/Microsoft.Resources/deployments/{name}",
        dep_body,
    )
    if resp.status_code != 200:
        wire.andon(f"deployment PUT {name}", status=resp.status_code)

    applied, refused = [], []
    for res in resources:
        res = {**res, "name": _substitute_parameters(res.get("name", ""), params)}
        path = _resource_path(subscription, resource_group, res)
        if path is None:
            refused.append({"resource": res.get("name", "?"),
                            "reason": "missing type/name"})
            continue
        # Materialize with the full resource body (location/sku/properties),
        # minus the URL-carried identity fields.
        body = {k: _substitute_parameters(v, params)
                for k, v in res.items()
                if k not in ("type", "name", "apiVersion")}
        rresp = wire.arm_put(path, body or {})
        # 202 = accepted-for-provisioning (ARM async semantics).
        if rresp.status_code in (200, 201, 202):
            applied.append(res.get("name", "?"))
        else:
            refused.append({"resource": res.get("name", "?"),
                            "status": rresp.status_code})
    if refused:
        wire.andon(f"deployment {name}: resource PUTs refused {refused}")
    wire.emit({"deployment": name, "provisioningState": "Succeeded",
               "resourcesApplied": applied}, output, title=f"deployment {name}")


@app.command("show")
def show(
    name: str = typer.Argument(...),
    resource_group: str = typer.Option("cli-rg", "--resource-group", "-g"),
    subscription: str = typer.Option("smalt-sub", "--subscription", "-s"),
    output: str = typer.Option("json", "--output", "-o"),
) -> None:
    """GET a deployment record."""
    resp = wire.arm_get(
        f"subscriptions/{subscription}/resourceGroups/{resource_group}/"
        f"providers/Microsoft.Resources/deployments/{name}")
    wire.expect(resp, (200,), f"deployment show {name}")
    wire.emit(resp.json(), output, title=name)
