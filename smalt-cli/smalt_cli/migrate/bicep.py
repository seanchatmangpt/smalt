"""Bicep extraction for smalt-migrate (PRD Module 1, REQ-1.1 increment).

Extracts `resource <sym> '<Type>@<apiVersion>' = { ... }` declarations from
.bicep files and projects them onto the SAME ResourceBlock shape the
Terraform extractor emits (smalt_cli/migrate/terraform.py), so build_topology
consumes both source languages uniformly.

Regex + line/brace extraction (acceptable for this increment). Bicep string
interpolation `'...${expr}...'` is typed unresolved, never guessed — mirroring
the HCL `${...}` rule. Unsupported ARM types land in `unsupported_types`,
never silently dropped.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .terraform import ResourceBlock, ScanError, ScanResult, _match_braces, _strip_comments

# ARM/bicep type -> the tf_type identifier build_topology dispatches on.
BICEP_TYPE_MAP: dict[str, str] = {
    "Microsoft.DocumentDB/databaseAccounts": "azurerm_cosmosdb_account",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases": "azurerm_cosmosdb_sql_database",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers": "azurerm_cosmosdb_sql_container",
    "Microsoft.Storage/storageAccounts/blobServices/containers": "azurerm_storage_container",
    "Microsoft.ServiceBus/namespaces": "azurerm_servicebus_namespace",
    "Microsoft.ServiceBus/namespaces/queues": "azurerm_servicebus_namespace_queue",
    "Microsoft.ServiceBus/namespaces/topics": "azurerm_servicebus_topic",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions": "azurerm_servicebus_subscription",
    "Microsoft.EventHub/namespaces": "azurerm_eventhub_namespace",
    "Microsoft.EventHub/namespaces/eventhubs": "azurerm_eventhub",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups": "azurerm_eventhub_consumer_group",
    "Microsoft.KeyVault/vaults": "azurerm_key_vault",
    "Microsoft.KeyVault/vaults/secrets": "azurerm_key_vault_secret",
    "Microsoft.ApiManagement/service": "azurerm_api_management",
}

# resource <sym> '<Type>' = { ... }   (rest-of-line captured for '='/'{' location)
_RESOURCE_OPEN = re.compile(
    r"(?m)^resource\s+(?P<sym>[A-Za-z_][A-Za-z0-9_]*)\s+'(?P<type>[^']+)'(?P<rest>[^\n]*)"
)

# nested `parent:` refs live at resource top level only
_PARENT_LINE = re.compile(r"^\s{0,4}parent\s*:\s*'?([A-Za-z_][A-Za-z0-9_]*)'?\s*$")

_LINE = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(.*?)\s*$")

_INTERP = re.compile(r"\$\{")

_UNSET = object()


def parse_file(path: Path) -> ScanResult:
    """Parse one .bicep file into tf-projected ResourceBlocks. Two-pass:
    collect raw resources first, then resolve `parent:` symbol chains into
    the parent-ref attributes build_topology dispatches on."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return ScanResult(
            [], [ScanError(file=str(path), error=str(exc), error_class="unreadable_file")], 1, {}
        )

    text = _strip_comments(text)
    raws: list[dict[str, Any]] = []
    errors: list[ScanError] = []
    for m in _RESOURCE_OPEN.finditer(text):
        sym = m.group("sym")
        arm_type, _, _api = m.group("type").strip().partition("@")
        arm_type = arm_type.strip()
        rest = m.group("rest")
        eq = rest.find("=")
        if eq < 0:
            errors.append(
                ScanError(
                    file=str(path),
                    error=f"no '=' for resource '{sym}' ({arm_type})",
                    error_class="unparsable_file",
                )
            )
            continue
        brace_in_rest = rest.find("{", eq)
        if brace_in_rest < 0:
            errors.append(
                ScanError(
                    file=str(path),
                    error=f"no body found for resource '{sym}' ({arm_type})",
                    error_class="unparsable_file",
                )
            )
            continue
        # offset from the START of `rest` within the full line (m.end() is the
        # line end — do not add to it)
        open_idx = m.start("rest") + brace_in_rest
        end = _match_braces(text, open_idx)
        if end < 0:
            errors.append(
                ScanError(
                    file=str(path),
                    error=f"unbalanced braces in resource '{sym}' ({arm_type})",
                    error_class="unparsable_file",
                )
            )
            continue
        body = text[open_idx + 1 : end - 1]
        raws.append(
            {
                "sym": sym,
                "arm_type": arm_type,
                "attrs": _extract_attrs(body),
            }
        )

    return _resolve_and_project(raws, errors, path)


def _resolve_and_project(
    raws: list[dict[str, Any]], errors: list[ScanError], path: Path
) -> ScanResult:
    blocks: list[ResourceBlock] = []
    unsupported: dict[str, int] = {}
    by_sym = {r["sym"]: r for r in raws}

    def ancestor(r: dict[str, Any], stop_types: tuple[str, ...]) -> dict[str, Any] | None:
        """Walk the parent: chain up to the first resource whose arm_type is
        in stop_types."""
        cur = r
        seen: set[str] = set()
        while True:
            psym = cur["attrs"].get("_parent_symbol")
            if not isinstance(psym, str) or psym in seen or psym not in by_sym:
                return None
            seen.add(psym)
            parent = by_sym[psym]
            if parent["arm_type"] in stop_types:
                return parent
            cur = parent

    for r in raws:
        arm = r["arm_type"]
        tf_type = BICEP_TYPE_MAP.get(arm)
        attrs = dict(r["attrs"])
        attrs.pop("_parent_symbol", None)

        # parent-chain -> parent-name refs (plain strings; unresolved is
        # expressed by their ABSENCE, matching the tf-shape contract)
        if arm.endswith("/sqlDatabases"):
            acct = ancestor(r, ("Microsoft.DocumentDB/databaseAccounts",))
            if acct:
                attrs["account_name"] = acct["attrs"].get("name")
        elif arm == "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers":
            db = ancestor(r, ("Microsoft.DocumentDB/databaseAccounts/sqlDatabases",))
            if db:
                attrs["database_name"] = db["attrs"].get("name")
            if "paths" in attrs:
                attrs["partition_key_paths"] = attrs.pop("paths")
        elif arm in (
            "Microsoft.ServiceBus/namespaces/queues",
            "Microsoft.ServiceBus/namespaces/topics",
            "Microsoft.EventHub/namespaces/eventhubs",
        ):
            ns = ancestor(r, ("Microsoft.ServiceBus/namespaces", "Microsoft.EventHub/namespaces"))
            if ns:
                attrs["namespace_name"] = ns["attrs"].get("name")
        elif arm == "Microsoft.ServiceBus/namespaces/topics/subscriptions":
            topic = ancestor(r, ("Microsoft.ServiceBus/namespaces/topics",))
            if topic:
                attrs["topic_name"] = topic["attrs"].get("name")
                ns = ancestor(
                    topic, ("Microsoft.ServiceBus/namespaces", "Microsoft.EventHub/namespaces")
                )
                if ns:
                    attrs["namespace_name"] = ns["attrs"].get("name")
        elif arm == "Microsoft.EventHub/namespaces/eventhubs/consumergroups":
            hub = ancestor(r, ("Microsoft.EventHub/namespaces/eventhubs",))
            if hub:
                attrs["eventhub_name"] = hub["attrs"].get("name")
                ns = ancestor(
                    hub, ("Microsoft.ServiceBus/namespaces", "Microsoft.EventHub/namespaces")
                )
                if ns:
                    attrs["namespace_name"] = ns["attrs"].get("name")
        elif arm == "Microsoft.KeyVault/vaults/secrets":
            vault = ancestor(r, ("Microsoft.KeyVault/vaults",))
            if vault:
                # build_topology matches secrets by vault hcl_name containment
                attrs["key_vault_id"] = vault["sym"]
        elif arm == "Microsoft.Storage/storageAccounts/blobServices/containers":
            name = attrs.get("name")
            if isinstance(name, str) and "/" in name:
                head, _, tail = name.rpartition("/")
                attrs["name"] = tail
                attrs["storage_account_name"] = head.split("/")[0]

        # properties.* / sku.* flattening -> tf attribute names
        for key in [k for k in attrs if isinstance(k, str) and k.startswith("properties.")]:
            val = attrs.pop(key)
            tf_key = _CAMEL_SNAKE.sub("_", key[len("properties.") :]).lower()
            if tf_key == "partition_key.paths":
                tf_key = "partition_key_paths"
            attrs.setdefault(tf_key, val)
        if "sku.name" in attrs:
            attrs.setdefault("sku", attrs.pop("sku.name"))

        if tf_type is None:
            unsupported[arm] = unsupported.get(arm, 0) + 1
            continue
        blocks.append(
            ResourceBlock(tf_type=tf_type, hcl_name=r["sym"], file=str(path), attributes=attrs)
        )

    return ScanResult(blocks, errors, 1, unsupported)


_CAMEL_SNAKE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")


def _extract_attrs(body: str) -> dict[str, Any]:
    """Recursive indent-aware extraction: `key: value` scalars, nested
    `key: { ... }` blocks flattened with dotted keys (sku.name,
    properties.partitionKey.paths), `parent: symbol` captured as
    _parent_symbol. Objects/arrays that are not simple string lists are typed
    unresolved, never guessed."""
    out: dict[str, Any] = {}
    lines = body.splitlines()
    _parse_block(lines, 0, -1, out)
    return out


def _parse_block(lines: list[str], start: int, min_indent: int, out: dict[str, Any]) -> int:
    i, n = start, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = _LINE.match(line)
        if not m:
            i += 1
            continue
        indent, key, val = len(m.group(1)), m.group(2), m.group(3)
        if indent <= min_indent:
            return i  # block ended
        if key == "parent" and indent <= 4:
            pm = _PARENT_LINE.match(line.strip())
            if pm:
                out["_parent_symbol"] = pm.group(1)
            i += 1
            continue
        stripped = val.rstrip(",")
        if stripped.endswith("{"):
            child: dict[str, Any] = {}
            i = _parse_block(lines, i + 1, indent, child)
            for k2, v2 in child.items():
                out[f"{key}.{k2}"] = v2
            continue
        sv = _scalar(stripped)
        if sv is not _UNSET:
            out[key] = sv
        i += 1
    return i


def _scalar(raw: str) -> Any:
    raw = raw.strip().rstrip(",").strip()
    if not raw:
        return _UNSET
    sm = re.fullmatch(r"'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"", raw)
    if sm:
        val = sm.group(1) if sm.group(1) is not None else sm.group(2)
        val = val.replace("\\'", "'").replace('\\"', '"').replace("\\\\", "\\")
        if _INTERP.search(val):
            return {"raw": val, "unresolved": True}
        return val
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    if raw in ("true", "false"):
        return raw == "true"
    lm = re.fullmatch(r"\[\s*((?:'[^']*'\s*,?\s*)*)\]", raw)
    if lm:
        items = re.findall(r"'([^']*)'", lm.group(1))
        if items:
            return items
    if raw.startswith("[") or raw.startswith("{"):
        return {"raw": raw, "unresolved": True}
    return _UNSET


def scan_dir(directory: Path) -> ScanResult:
    """Scan a directory recursively for .bicep files."""
    blocks: list[ResourceBlock] = []
    errors: list[ScanError] = []
    unsupported: dict[str, int] = {}
    files = 0
    try:
        bicep_files = sorted(directory.rglob("*.bicep"))
    except OSError as exc:
        return ScanResult(
            [], [ScanError(file=str(directory), error=str(exc), error_class="unreadable_dir")], 0, {}
        )
    for f in bicep_files:
        res = parse_file(f)
        files += res.files_scanned
        blocks.extend(res.blocks)
        errors.extend(res.errors)
        for t, c in res.unsupported_types.items():
            unsupported[t] = unsupported.get(t, 0) + c
    return ScanResult(blocks, errors, files, unsupported)
