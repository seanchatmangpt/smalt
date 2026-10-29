"""`smalt-migrate generate` — topology IR -> smalt.manifest.json (PRD REQ-2.1, NFR-3).

Consumes the topology from ``smalt_cli.migrate.scan.build_topology`` and emits a
deterministic manifest: same input -> byte-identical output (sorted keys, no
timestamps; the iac-path is part of the input identity). Seed fixtures carry
sample documents per cosmos container, honoring each container's declared
partition key path; unresolved references surface as typed manifest fields,
never guessed.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any, Optional

import typer

MANIFEST_NAME = "smalt.manifest.json"
MANIFEST_VERSION = 1


def build_manifest(topology: dict[str, Any]) -> dict[str, Any]:
    """Project a scan topology into the manifest IR.

    Sections mirror the PRD table: identity / cosmos_databases / apim_gateways
    / messaging_namespaces / security_vaults / object_storage, plus the
    discovered service set (same mapping as inject, sorted) and seed
    fixtures for every resolved cosmos container.
    """
    from .inject import discovered_services
    from .verify import VERIFIERS

    discovered = discovered_services(topology)
    # verify.py is the manifest's only consumer; translate discovery names to
    # verify's canonical names (keyvault -> kv); services without a verifier
    # (eventhubs today) are carried as a typed remainder, never dropped.
    _DISCOVERY_TO_VERIFY = {"keyvault": "kv"}
    named = {_DISCOVERY_TO_VERIFY.get(s, s) for s in discovered}
    verifiable = sorted(s for s in named if s in VERIFIERS)
    unverifiable = sorted(
        s for s in discovered if _DISCOVERY_TO_VERIFY.get(s, s) not in VERIFIERS
    )

    return {
        "version": MANIFEST_VERSION,
        "services": verifiable,
        "unverifiable_services": unverifiable,
        "identity": [],
        "cosmos_databases": _attach_seed_documents(
            copy.deepcopy(topology.get("cosmos_databases") or [])
        ),
        "apim_gateways": copy.deepcopy(topology.get("apim_gateways") or []),
        "messaging_namespaces": copy.deepcopy(topology.get("messaging_namespaces") or []),
        "security_vaults": copy.deepcopy(topology.get("security_vaults") or []),
        "object_storage": copy.deepcopy(topology.get("object_storage") or []),
        "seed_fixtures": _seed_fixtures(copy.deepcopy(topology.get("cosmos_databases") or [])),
        "unresolved_summary": _unresolved_summary(topology),
    }


def _attach_seed_documents(cosmos_entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Attach ``seed_documents`` to every container with a resolved database
    (nested under an account, a top-level database, or an account-less
    container entry)."""
    for entry in cosmos_entries:
        for db in entry.get("databases", []) or []:
            for container in db.get("containers", []) or []:
                container["seed_documents"] = _seed_documents(container)
        for container in entry.get("containers", []) or []:
            container["seed_documents"] = _seed_documents(container)
    return cosmos_entries


def _seed_fixtures(cosmos_entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """One seed-fixture row per resolved container: container name, database
    name (when known), partition key path, and the sample documents."""
    rows: list[dict[str, Any]] = []
    for entry in cosmos_entries:
        acct_name = entry.get("name") if "databases" in entry else None
        pairs: list[tuple[Optional[str], dict[str, Any]]] = []
        for db in entry.get("databases", []) or []:
            for container in db.get("containers", []) or []:
                pairs.append((db.get("name"), container))
        for container in entry.get("containers", []) or []:
            pairs.append((entry.get("name"), container))
        for db_name, container in pairs:
            docs = container.get("seed_documents")
            if docs is None:
                docs = _seed_documents(container)
            rows.append(
                {
                    "container": container.get("name"),
                    "database": db_name,
                    "account": acct_name,
                    "partition_key_path": (container.get("partition_key_paths") or [None])[0],
                    "documents": docs,
                }
            )
    return rows


def _seed_documents(container: dict[str, Any]) -> list[dict[str, Any]]:
    """Two deterministic sample documents honoring the container's declared
    partition key path. ``/tenantId`` -> ``{"tenantId": ...}``; a nested path
    ``/a/b`` nests the object; a pk-less container gets documents carrying
    ``id`` only (the absence is typed, not guessed)."""
    name = str(container.get("name") or "container")
    paths = container.get("partition_key_paths") or []
    pk_path = paths[0] if paths else None
    docs: list[dict[str, Any]] = []
    for seq in ("0001", "0002"):
        doc: dict[str, Any] = {"id": f"seed-{name}-{seq}"}
        if pk_path:
            _set_path(doc, str(pk_path).lstrip("/"), f"{name}-sample-{seq}")
        doc["_smalt"] = {
            "partition_key_path": pk_path,
            "container": container.get("name"),
        }
        docs.append(doc)
    return docs


def _set_path(doc: dict[str, Any], dotted: str, value: Any) -> None:
    node = doc
    parts = dotted.split("/")
    for part in parts[:-1]:
        nxt = node.setdefault(part, {})
        if not isinstance(nxt, dict):
            return
        node = nxt
    node[parts[-1]] = value


def _unresolved_summary(topology: dict[str, Any]) -> dict[str, Any]:
    cosmos = topology.get("cosmos_databases") or []
    return {
        "accountless_databases": sum(
            1
            for e in cosmos
            if isinstance(e, dict) and e.get("account_ref_unresolved")
        ),
        "orphan_containers": sum(
            1
            for e in cosmos
            if isinstance(e, dict) and e.get("database_ref_unresolved")
        ),
        "storage_account_refs_unresolved": sum(
            1
            for e in topology.get("object_storage") or []
            if isinstance(e, dict) and e.get("storage_account_ref_unresolved")
        ),
        "orphan_namespaces": sum(
            1
            for e in topology.get("messaging_namespaces") or []
            if isinstance(e, dict) and e.get("orphan_namespace")
        ),
        "orphan_vaults": sum(
            1
            for e in topology.get("security_vaults") or []
            if isinstance(e, dict) and e.get("orphan_vault")
        ),
        "scan_errors": len(topology.get("errors") or []),
    }


def render_manifest(manifest: dict[str, Any]) -> str:
    """Byte-deterministic serialization (NFR-3): sorted keys, 2-space indent,
    trailing newline, no timestamps anywhere in the payload."""
    return json.dumps(manifest, indent=2, sort_keys=True) + "\n"


def generate(iac_path: Path, output_dir: Path) -> dict[str, Any]:
    """Scan ``iac_path`` and write ``smalt.manifest.json`` under ``output_dir``.
    Returns the parsed manifest for callers that need the object form."""
    from .scan import build_topology
    from .terraform import scan_dir

    topo = build_topology(scan_dir(iac_path))
    manifest = build_manifest(topo)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / MANIFEST_NAME).write_text(render_manifest(manifest), encoding="utf-8")
    return manifest


def generate_command(
    iac_path: Path = typer.Option(
        ...,
        "--iac-path",
        exists=True,
        file_okay=False,
        readable=True,
        help="Directory of Terraform (.tf) files to migrate.",
    ),
    output_dir: Path = typer.Option(
        ...,
        "--output-dir",
        file_okay=False,
        help="Directory that receives smalt.manifest.json.",
    ),
) -> int:
    """Generate smalt.manifest.json from a Terraform directory."""
    manifest = generate(iac_path, output_dir)
    summary = manifest["unresolved_summary"]
    typer.echo(
        f"manifest written: {output_dir / MANIFEST_NAME} "
        f"(cosmos_containers={_count_containers(manifest['cosmos_databases'])} "
        f"seed_fixtures={len(manifest['seed_fixtures'])} "
        f"scan_errors={summary['scan_errors']})",
        err=True,
    )
    return 0


def _count_containers(cosmos_entries: list[dict[str, Any]]) -> int:
    n = 0
    for entry in cosmos_entries:
        for db in entry.get("databases", []) or []:
            n += len(db.get("containers", []) or [])
        n += len(entry.get("containers", []) or [])
    return n
