"""`smalt-cli migrate scan` — Terraform .tf -> smalt topology IR (PRD Module 1, REQ-1.1).

Maps extracted azurerm resource blocks to the PRD's IR sections:
  cosmos_databases, object_storage, messaging_namespaces, security_vaults,
  apim_gateways. Interpolated attribute values and bare HCL references are
  typed; interpolations carry `unresolved: true`. A child whose parent link
  cannot be resolved to a declared parent surfaces via a typed
  `*_ref_unresolved` flag / orphan bucket — never silently dropped. An
  unparsable file produces a typed entry in `errors`.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import typer

from .terraform import ResourceBlock, ScanResult, scan_dir

migrate_app = typer.Typer(name="migrate", help="Terraform -> smalt topology migration.")


# ---------- attribute helpers ----------

def _is_unresolved(v: Any) -> bool:
    return isinstance(v, dict) and v.get("unresolved") is True


def _unresolved_attr_names(attrs: dict[str, Any]) -> list[str]:
    return sorted(k for k, v in attrs.items() if _is_unresolved(v))


def _raw(v: Any) -> Any:
    if isinstance(v, dict):
        return v["raw"] if "raw" in v else v.get("ref")
    return v


def _source(b: ResourceBlock) -> dict[str, Any]:
    return {"file": b.file, "hcl_name": b.hcl_name}


def _resolve_parent(
    attrs: dict[str, Any],
    key: str,
    by_hcl: dict[str, dict[str, Any]],
    by_name: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any] | None:
    """Resolve a child's parent link to a declared parent entry — by HCL label
    (bare reference) or by literal name value. None = unresolved."""
    v = attrs.get(key)
    if v is None:
        return None
    if isinstance(v, dict):
        hcl = v.get("ref_hcl")
        if hcl is not None and hcl in by_hcl:
            return by_hcl[hcl]
        raw = v.get("raw")
        if isinstance(raw, str) and by_name and raw in by_name:
            return by_name[raw]
        return None
    if isinstance(v, str) and by_name and v in by_name:
        return by_name[v]
    return None


def build_topology(result: ScanResult) -> dict[str, Any]:
    topo: dict[str, Any] = {
        "schema": "smalt-migrate/topology-v1",
        "cosmos_databases": [],
        "object_storage": [],
        "messaging_namespaces": [],
        "security_vaults": [],
        "apim_gateways": [],
        "errors": [],
        "unsupported_resource_types": {},
        "files_scanned": result.files_scanned,
    }

    # Pass 1: mint declared entries keyed for parent resolution.
    accounts_hcl: dict[str, dict[str, Any]] = {}
    accounts_name: dict[str, dict[str, Any]] = {}
    dbs_hcl: dict[str, dict[str, Any]] = {}
    dbs_name: dict[str, dict[str, Any]] = {}
    sb_ns_hcl: dict[str, dict[str, Any]] = {}
    sb_ns_name: dict[str, dict[str, Any]] = {}
    sb_topic_hcl: dict[str, dict[str, Any]] = {}
    sb_topic_name: dict[str, dict[str, Any]] = {}
    eh_ns_hcl: dict[str, dict[str, Any]] = {}
    eh_ns_name: dict[str, dict[str, Any]] = {}
    eh_hub_hcl: dict[str, dict[str, Any]] = {}
    eh_hub_name: dict[str, dict[str, Any]] = {}
    vault_hcl: dict[str, dict[str, Any]] = {}
    vault_name: dict[str, dict[str, Any]] = {}

    queues: list[dict[str, Any]] = []
    topics: list[dict[str, Any]] = []
    subs: list[dict[str, Any]] = []
    hubs: list[dict[str, Any]] = []
    cgs: list[dict[str, Any]] = []
    secrets: list[dict[str, Any]] = []
    dbs: list[dict[str, Any]] = []
    containers: list[dict[str, Any]] = []

    for b in result.blocks:
        a = b.attributes
        t = b.tf_type
        if t == "azurerm_cosmosdb_account":
            e = {
                "name": a.get("name"),
                "resource_group": a.get("resource_group_name"),
                "location": a.get("location"),
                "databases": [],
                "unresolved_attrs": _unresolved_attr_names(a),
                "source": _source(b),
            }
            accounts_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                accounts_name[a["name"]] = e
        elif t == "azurerm_cosmosdb_sql_database":
            e = {
                "name": a.get("name"),
                "throughput": a.get("offer_throughput"),
                "containers": [],
                "attrs": a,
                "source": _source(b),
            }
            dbs.append(e)
            dbs_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                dbs_name[a["name"]] = e
        elif t == "azurerm_cosmosdb_sql_container":
            pk = a.get("partition_key_paths")
            containers.append(
                {
                    "name": a.get("name"),
                    "partition_key_paths": pk if isinstance(pk, list) else ([pk] if pk is not None else []),
                    "throughput": a.get("throughput"),
                    "attrs": a,
                    "source": _source(b),
                }
            )
        elif t == "azurerm_storage_container":
            topo["object_storage"].append(
                {
                    "name": a.get("name"),
                    "storage_account_ref": a.get("storage_account_name"),
                    "storage_account_ref_unresolved": _is_unresolved(a.get("storage_account_name")),
                    "source": _source(b),
                }
            )
        elif t == "azurerm_servicebus_namespace":
            e = {
                "kind": "servicebus",
                "name": a.get("name"),
                "sku": a.get("sku"),
                "queues": [],
                "topics": [],
                "unresolved_attrs": _unresolved_attr_names(a),
                "source": _source(b),
            }
            sb_ns_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                sb_ns_name[a["name"]] = e
        elif t == "azurerm_servicebus_namespace_queue":
            queues.append(
                {
                    "name": a.get("name"),
                    "max_delivery_count": a.get("max_delivery_count"),
                    "lock_duration": a.get("lock_duration"),
                    "attrs": a,
                    "source": _source(b),
                }
            )
        elif t == "azurerm_servicebus_topic":
            e = {"name": a.get("name"), "subscriptions": [], "attrs": a, "source": _source(b)}
            topics.append(e)
            sb_topic_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                sb_topic_name[a["name"]] = e
        elif t == "azurerm_servicebus_subscription":
            subs.append(
                {
                    "name": a.get("name"),
                    "max_delivery_count": a.get("max_delivery_count"),
                    "attrs": a,
                    "source": _source(b),
                }
            )
        elif t == "azurerm_eventhub_namespace":
            e = {
                "kind": "eventhub",
                "name": a.get("name"),
                "sku": a.get("sku"),
                "capacity": a.get("capacity"),
                "eventhubs": [],
                "unresolved_attrs": _unresolved_attr_names(a),
                "source": _source(b),
            }
            eh_ns_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                eh_ns_name[a["name"]] = e
        elif t == "azurerm_eventhub":
            e = {
                "name": a.get("name"),
                "partition_count": a.get("partition_count"),
                "message_retention_in_days": a.get("message_retention_in_days"),
                "consumer_groups": [],
                "attrs": a,
                "source": _source(b),
            }
            hubs.append(e)
            eh_hub_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                eh_hub_name[a["name"]] = e
        elif t == "azurerm_eventhub_consumer_group":
            cgs.append({"name": a.get("name"), "attrs": a, "source": _source(b)})
        elif t == "azurerm_key_vault":
            e = {
                "name": a.get("name"),
                "resource_group": a.get("resource_group_name"),
                "secrets": [],
                "unresolved_attrs": _unresolved_attr_names(a),
                "source": _source(b),
            }
            vault_hcl[b.hcl_name] = e
            if isinstance(a.get("name"), str):
                vault_name[a["name"]] = e
        elif t == "azurerm_key_vault_secret":
            secrets.append(
                {
                    "name": a.get("name"),
                    "value": None,  # secret values are never echoed into the topology
                    "attrs": a,
                    "source": _source(b),
                }
            )
        elif t == "azurerm_api_management":
            topo["apim_gateways"].append(
                {
                    "name": a.get("name"),
                    "publisher_name": a.get("publisher_name"),
                    "publisher_email": a.get("publisher_email"),
                    "sku": a.get("sku_name"),
                    "unresolved_attrs": _unresolved_attr_names(a),
                    "source": _source(b),
                }
            )

    # Pass 2: attach children to resolved parents; unresolved -> typed orphan.
    orphan_dbs: list[dict[str, Any]] = []
    orphan_containers: list[dict[str, Any]] = []
    orphan_queues: list[dict[str, Any]] = []
    orphan_topics: list[dict[str, Any]] = []
    orphan_subs: list[dict[str, Any]] = []
    orphan_hubs: list[dict[str, Any]] = []
    orphan_cgs: list[dict[str, Any]] = []
    orphan_secrets: list[dict[str, Any]] = []

    for e in dbs:
        a = e.pop("attrs", None) or {}
        acct = _resolve_parent(a, "account_name", accounts_hcl, accounts_name)
        e["account_ref_unresolved"] = acct is None
        if acct is not None:
            acct["databases"].append(e)
        else:
            orphan_dbs.append(e)
    for e in containers:
        a = e.pop("attrs", None) or {}
        db = _resolve_parent(a, "database_name", dbs_hcl, dbs_name)
        e["database_ref_unresolved"] = db is None
        e.pop("attrs", None)
        if db is not None:
            db["containers"].append(e)
        else:
            orphan_containers.append(e)

    sb_orphans = orphan_queues
    eh_orphans = orphan_hubs
    for e in queues:
        a = e.pop("attrs", None) or {}
        ns = _resolve_parent(a, "namespace_name", sb_ns_hcl, sb_ns_name)
        e["namespace_ref_unresolved"] = ns is None
        if ns is not None:
            ns["queues"].append(e)
        else:
            sb_orphans.append(e)
    for e in topics:
        a = e.pop("attrs", None) or {}
        ns = _resolve_parent(a, "namespace_name", sb_ns_hcl, sb_ns_name)
        e["namespace_ref_unresolved"] = ns is None
        if ns is not None:
            ns["topics"].append(e)
        else:
            orphan_topics.append(e)
    for e in subs:
        a = e.pop("attrs", None) or {}
        ns = _resolve_parent(a, "namespace_name", sb_ns_hcl, sb_ns_name)
        topic = _resolve_parent(a, "topic_name", sb_topic_hcl, sb_topic_name)
        e["namespace_ref_unresolved"] = ns is None
        e["topic_ref_unresolved"] = topic is None
        if ns is not None and topic is not None:
            topic["subscriptions"].append(e)
        else:
            orphan_subs.append(e)
    for e in hubs:
        a = e.pop("attrs", None) or {}
        ns = _resolve_parent(a, "namespace_name", eh_ns_hcl, eh_ns_name)
        e["namespace_ref_unresolved"] = ns is None
        if ns is not None:
            ns["eventhubs"].append(e)
        else:
            eh_orphans.append(e)
    for e in cgs:
        a = e.pop("attrs", None) or {}
        ns = _resolve_parent(a, "namespace_name", eh_ns_hcl, eh_ns_name)
        hub = _resolve_parent(a, "eventhub_name", eh_hub_hcl, eh_hub_name)
        e["namespace_ref_unresolved"] = ns is None
        e["eventhub_ref_unresolved"] = hub is None
        if ns is not None and hub is not None:
            hub["consumer_groups"].append(e)
        else:
            orphan_cgs.append(e)
    for e in secrets:
        a = e.pop("attrs", None) or {}
        vault = _resolve_parent(a, "key_vault_id", vault_hcl, vault_name)
        e["vault_ref_unresolved"] = vault is None
        if vault is not None:
            vault["secrets"].append(e)
        else:
            orphan_secrets.append(e)
    # Emit: declared namespaces (already carrying children), then typed orphan buckets.
    topo["cosmos_databases"].extend(accounts_hcl.values())
    topo["cosmos_databases"].extend(orphan_dbs)
    topo["cosmos_databases"].extend(orphan_containers)
    for e in sb_ns_hcl.values():
        topo["messaging_namespaces"].append(e)
    for e in eh_ns_hcl.values():
        topo["messaging_namespaces"].append(e)
    if orphan_queues or orphan_topics or orphan_subs:
        topo["messaging_namespaces"].append(
            {
                "kind": "servicebus",
                "name": None,
                "orphan_namespace": True,
                "queues": orphan_queues,
                "topics": orphan_topics + [
                    {"name": s.get("name"), "subscriptions": [s], "namespace_ref_unresolved": True,
                     "topic_ref_unresolved": True, "source": s.get("source")}
                    for s in orphan_subs
                ],
                "namespace_ref_unresolved": True,
                "source": None,
            }
        )
    if orphan_hubs or orphan_cgs:
        topo["messaging_namespaces"].append(
            {
                "kind": "eventhub",
                "name": None,
                "orphan_namespace": True,
                "eventhubs": orphan_hubs
                + [
                    {"name": c.get("name"), "consumer_groups": [c], "namespace_ref_unresolved": True,
                     "eventhub_ref_unresolved": True, "source": c.get("source")}
                    for c in orphan_cgs
                ],
                "namespace_ref_unresolved": True,
                "source": None,
            }
        )
    topo["security_vaults"].extend(vault_hcl.values())
    if orphan_secrets:
        topo["security_vaults"].append(
            {"name": None, "orphan_vault": True, "secrets": orphan_secrets, "vault_ref_unresolved": True}
        )

    # ---------- Fail-closed error surface ----------
    topo["errors"] = [
        {"file": e.file, "error": e.error, "error_class": e.error_class} for e in result.errors
    ]
    topo["unsupported_resource_types"] = dict(sorted(result.unsupported_types.items()))
    return topo


@migrate_app.command(name="scan")
def scan(
    directory: Path = typer.Argument(..., exists=True, file_okay=False, readable=True, help="Directory containing .tf / .bicep files."),
    output: Path = typer.Option(None, "--output", "-o", help="Write topology JSON here instead of stdout."),
) -> None:
    """Scan a directory of Terraform/Bicep and emit the smalt topology IR (JSON)."""
    result = scan_dir(directory)
    topo = build_topology(result)
    payload = json.dumps(topo, indent=2)
    if output is not None:
        output.write_text(payload + "\n", encoding="utf-8")
        typer.echo(
            f"topology written: {output} "
            f"(files_scanned={topo['files_scanned']} errors={len(topo['errors'])})",
            err=True,
        )
    else:
        typer.echo(payload)
