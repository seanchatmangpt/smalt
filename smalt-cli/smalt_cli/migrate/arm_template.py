"""ARM template JSON extraction for smalt-migrate (PRD Module 1, third language).

Parses Azure ARM template .json files (`resources[]` with
type/name/apiVersion/properties, nested child `resources[]`, and top-level
name-slash child paths) and projects them onto the SAME ResourceBlock shape
the Terraform and Bicep extractors emit (smalt_cli/migrate/terraform.py), so
build_topology consumes all three source languages uniformly.

ARM expressions (`[parameters('x')]`, `[variables('y')]`, `concat(...)`) are
typed unresolved (`{"raw": ..., "unresolved": True}`), never guessed.
Unsupported ARM types land in `unsupported_types`, never silently dropped.
Fail-closed: malformed JSON surfaces as a typed ScanError.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .bicep import BICEP_TYPE_MAP, _CAMEL_SNAKE
from .terraform import ResourceBlock, ScanError, ScanResult

_HCL_ALNUM = re.compile(r"[^A-Za-z0-9_]")

# ARM type segments are case-insensitive; normalize both sides once.
_ARM_TYPE_MAP = {k.lower(): v for k, v in BICEP_TYPE_MAP.items()}


def _is_expr(v: Any) -> bool:
    return isinstance(v, str) and v.startswith("[") and v.endswith("]")


def _unresolved(v: str) -> dict[str, Any]:
    return {"raw": v, "unresolved": True}


def _convert(value: Any) -> Any:
    """Type an ARM JSON value: expressions unresolved, scalars plain,
    lists element-wise, dicts recursively."""
    if isinstance(value, str):
        return _unresolved(value) if _is_expr(value) else value
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, list):
        return [_convert(v) for v in value]
    if isinstance(value, dict):
        return {k: _convert(v) for k, v in value.items()}
    return value


def _flatten(prefix: str, value: Any, out: dict[str, Any]) -> None:
    """Flatten nested property dicts to dotted keys (properties.partitionKey.paths).
    Unresolved-marker dicts are leaves, never flattened."""
    if isinstance(value, dict) and value and "unresolved" not in value and "ref" not in value:
        for k, v in value.items():
            _flatten(f"{prefix}.{k}", v, out)
    else:
        out[prefix] = value


def _snake(key: str) -> str:
    key = key.replace("-", "_")
    return _CAMEL_SNAKE.sub("_", key).lower().replace(".", "_")


def parse_file(path: Path) -> ScanResult:
    """Parse one ARM template .json into tf-projected ResourceBlocks."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return ScanResult(
            [], [ScanError(file=str(path), error=str(exc), error_class="unreadable_file")], 1, {}
        )
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        return ScanResult(
            [],
            [
                ScanError(
                    file=str(path),
                    error=f"invalid JSON: {exc.msg} (line {exc.lineno})",
                    error_class="unparsable_file",
                )
            ],
            1,
            {},
        )
    if not isinstance(doc, dict):
        return ScanResult(
            [],
            [
                ScanError(
                    file=str(path),
                    error="template root is not a JSON object",
                    error_class="unparsable_file",
                )
            ],
            1,
            {},
        )

    raws: list[dict[str, Any]] = []
    errors: list[ScanError] = []

    def walk(resources: Any, parent: dict[str, Any] | None) -> None:
        if not isinstance(resources, list):
            return
        for r in resources:
            if not isinstance(r, dict):
                errors.append(
                    ScanError(
                        file=str(path),
                        error=f"resource entry is not an object: {r!r}",
                        error_class="unparsable_file",
                    )
                )
                continue
            arm_type = r.get("type")
            name = r.get("name")
            if not isinstance(arm_type, str) or not isinstance(name, str):
                errors.append(
                    ScanError(
                        file=str(path),
                        error=f"resource missing string 'type'/'name': type={arm_type!r} name={name!r}",
                        error_class="unparsable_file",
                    )
                )
                continue
            raw: dict[str, Any] = {
                "arm_type": arm_type,
                "name": _convert(name),
                "parent": parent,
                "attrs": {},
            }
            raws.append(raw)
            props = r.get("properties")
            if isinstance(props, dict):
                flat: dict[str, Any] = {}
                for k, v in props.items():
                    _flatten(k, _convert(v), flat)
                for k, v in flat.items():
                    raw["attrs"][_snake(k)] = v
            sku = r.get("sku")
            if isinstance(sku, dict):
                if isinstance(sku.get("name"), (str, dict)):
                    raw["attrs"]["sku"] = _convert(sku["name"])
                cap = sku.get("capacity")
                if isinstance(cap, (int, float)):
                    raw["attrs"]["capacity"] = cap
                    raw["_sku_capacity"] = cap
            walk(r.get("resources"), raw)

    walk(doc.get("resources"), None)
    blocks, unsupported = _project(raws, path)
    return ScanResult(blocks, errors, 1, unsupported)


def _project(raws: list[dict[str, Any]], path: Path) -> tuple[list[ResourceBlock], dict[str, int]]:
    """Resolve parent chains (nested resources and name-slash paths) into the
    parent-ref attributes build_topology dispatches on; count unsupported."""
    blocks: list[ResourceBlock] = []
    unsupported: dict[str, int] = {}

    def segs_of(arm_type: str) -> list[str]:
        return [seg.lower() for seg in arm_type.split("/")]

    def find_ancestor(raw: dict[str, Any], seg: str) -> dict[str, Any] | None:
        """Nearest declared ancestor whose type's final segment == seg."""
        cur = raw["parent"]
        while cur is not None:
            segs = segs_of(cur["arm_type"])
            if segs and segs[-1] == seg:
                return cur
            cur = cur["parent"]
        return None

    for raw in raws:
        arm = raw["arm_type"]
        tf_type = _ARM_TYPE_MAP.get(arm.lower())
        segs = segs_of(arm)
        attrs = dict(raw["attrs"])
        name = raw["name"]

        # A slash path in the name encodes ancestors relative to the declared
        # parent ("acct/db" under a resource group, "db/ctx" under its db).
        # Each slash segment resolves to an undeclared (virtual) ancestor —
        # resolved by literal name match downstream when the segment is a
        # plain string; expression segments stay typed unresolved.
        virtual: list[str] = []
        if isinstance(name, str) and "/" in name and not _is_expr(name):
            virtual = name.split("/")[:-1]
        attrs.setdefault("name", name.rpartition("/")[2] if virtual else name)

        def parent_ref(anc: dict[str, Any]) -> Any:
            """Parent name reference the build_topology matcher accepts:
            literal name strings match by_name; expression-named parents are
            matched by their deterministic hcl label (ref_hcl)."""
            nm = anc["name"]
            if isinstance(nm, str):
                return nm
            return {"ref": nm.get("raw", ""), "ref_hcl": _hcl_name(anc), "unresolved": True}

        def seg_name(back: int) -> Any:
            """Virtual ancestor name `back` segments up (1 = nearest)."""
            pos = len(virtual) - back
            if pos < 0:
                return None
            seg = virtual[pos]
            return _unresolved(seg) if _is_expr(seg) else seg

        if segs and segs[-1] == "databaseaccounts":
            pass  # root resource: nothing to resolve
        elif segs and segs[-1] == "sqldatabases":
            anc = find_ancestor(raw, "databaseaccounts")
            if anc is not None:
                attrs["account_name"] = parent_ref(anc)
            elif virtual:
                attrs["account_name"] = seg_name(len(virtual))
        elif segs and segs[-1] == "containers" and "sqldatabases" in segs:
            db = find_ancestor(raw, "sqldatabases")
            if db is not None:
                attrs["database_name"] = parent_ref(db)
            elif virtual:
                attrs["database_name"] = seg_name(1)
                if len(virtual) >= 2:
                    attrs["account_name"] = seg_name(2)
        elif len(segs) >= 2 and segs[-1] in ("queues", "topics") and segs[-2] == "namespaces":
            anc = find_ancestor(raw, "namespaces")
            if anc is not None:
                attrs["namespace_name"] = parent_ref(anc)
            elif virtual:
                attrs["namespace_name"] = seg_name(1)
        elif segs and segs[-1] == "subscriptions":
            topic = find_ancestor(raw, "topics")
            ns = find_ancestor(raw, "namespaces")
            if topic is not None:
                attrs["topic_name"] = parent_ref(topic)
            if ns is not None:
                attrs["namespace_name"] = parent_ref(ns)
            if "topic_name" not in attrs and virtual:
                attrs["topic_name"] = seg_name(1)
            if "namespace_name" not in attrs and len(virtual) >= 2:
                attrs["namespace_name"] = seg_name(2)
        elif segs and segs[-1] == "eventhubs":
            anc = find_ancestor(raw, "namespaces")
            if anc is not None:
                attrs["namespace_name"] = parent_ref(anc)
            elif virtual:
                attrs["namespace_name"] = seg_name(1)
        elif segs and segs[-1] == "consumergroups":
            hub = find_ancestor(raw, "eventhubs")
            ns = find_ancestor(raw, "namespaces")
            if hub is not None:
                attrs["eventhub_name"] = parent_ref(hub)
            if ns is not None:
                attrs["namespace_name"] = parent_ref(ns)
            if "eventhub_name" not in attrs and virtual:
                attrs["eventhub_name"] = seg_name(1)
            if "namespace_name" not in attrs and len(virtual) >= 2:
                attrs["namespace_name"] = seg_name(2)
        elif segs and segs[-1] == "secrets" and "vaults" in segs:
            vault = find_ancestor(raw, "vaults")
            if vault is not None:
                # build_topology matches secrets by vault hcl_name containment
                attrs["key_vault_id"] = parent_ref(vault)
            elif virtual:
                attrs["key_vault_id"] = seg_name(len(virtual))
        elif segs and segs[-1] == "containers" and "storageaccounts" in segs:
            # name-slash path "account/default/container": root segment is the
            # storage account; strip to the bare container name.
            anc = find_ancestor(raw, "storageaccounts")
            if anc is not None:
                attrs["storage_account_name"] = parent_ref(anc)
            elif virtual:
                attrs["storage_account_name"] = seg_name(len(virtual))

        # tf-shape aliases build_topology reads directly.
        if "options_throughput" in attrs:
            attrs.setdefault("offer_throughput", attrs["options_throughput"])
        if segs and segs[-1] == "service":
            # Microsoft.ApiManagement/service: tf reads sku_name
            if "sku" in attrs:
                attrs.setdefault("sku_name", attrs["sku"])
        sku_capacity = raw.get("_sku_capacity")
        if sku_capacity is not None:
            attrs.setdefault("capacity", sku_capacity)

        if tf_type is None:
            unsupported[arm] = unsupported.get(arm, 0) + 1
            continue
        blocks.append(
            ResourceBlock(
                tf_type=tf_type, hcl_name=_hcl_name(raw), file=str(path), attributes=attrs
            )
        )

    return blocks, unsupported


def _hcl_name(raw: dict[str, Any]) -> str:
    """Mint a stable hcl_name from the resource's literal name (or an
    expression-derived label) — build_topology keys parents by literal name,
    hcl_name is only the source label."""
    name = raw.get("name")
    if isinstance(name, str) and name:
        sym = _HCL_ALNUM.sub("_", name.rpartition("/")[2])
        return sym or arm_fallback(raw)
    rawstr = str(name.get("raw", "")) if isinstance(name, dict) else ""
    sym = _HCL_ALNUM.sub("_", rawstr)
    return f"expr_{sym}" if sym else arm_fallback(raw)


def arm_fallback(raw: dict[str, Any]) -> str:
    return raw["arm_type"].replace("/", "_")


def scan_dir(directory: Path) -> ScanResult:
    """Scan a directory recursively for *.arm.json ARM templates."""
    blocks: list[ResourceBlock] = []
    errors: list[ScanError] = []
    unsupported: dict[str, int] = {}
    files = 0
    try:
        arm_files = sorted(directory.rglob("*.arm.json"))
    except OSError as exc:
        return ScanResult(
            [], [ScanError(file=str(directory), error=str(exc), error_class="unreadable_dir")], 0, {}
        )
    for f in arm_files:
        res = parse_file(f)
        files += res.files_scanned
        blocks.extend(res.blocks)
        errors.extend(res.errors)
        for t, c in res.unsupported_types.items():
            unsupported[t] = unsupported.get(t, 0) + c
    return ScanResult(blocks, errors, files, unsupported)
