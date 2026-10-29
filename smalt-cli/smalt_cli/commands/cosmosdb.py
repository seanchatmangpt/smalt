"""cosmosdb sub-app: sql database/container create + document CRUD.

Wire face: Cosmos NoSQL face on the egress plane (/dbs...), NOT a separate
:8081 — the emulator mounts CosmosRoutes on the shared egress router.
Replace carries If-Match ETag-CAS; a stale etag is a 412 ANDON refusal.
"""
from __future__ import annotations

import json

import httpx
import typer

from .. import wire

app = typer.Typer(help="Cosmos DB NoSQL (egress plane /dbs).")


def _pk_header(db: str, coll: str, doc: dict) -> dict:
    """Derive the x-ms-documentdb-partitionkey header from the container's
    declared pk paths and the doc itself (mirrors the server-side
    PartitionKey.extract normalization: bool -> "true"/"false", else str())."""
    resp = wire.cosmos_request("GET", f"dbs/{db}/colls/{coll}")
    if resp.status_code != 200:
        return {}
    paths = ((resp.json() or {}).get("partitionKey") or {}).get("paths") or []
    for path in paths:
        cur = doc
        for seg in path.strip("/").split("/"):
            if not isinstance(cur, dict) or seg not in cur:
                cur = None
                break
            cur = cur[seg]
        if cur is None or isinstance(cur, (dict, list)):
            continue
        val = ("true" if cur else "false") if isinstance(cur, bool) else str(cur)
        return {"x-ms-documentdb-partitionkey": json.dumps([val])}
    return {}


def _cosmos(resp: httpx.Response, ok, what):
    wire.expect(resp, ok, what)
    body = None
    if resp.content:
        try:
            body = resp.json()
        except ValueError:
            body = resp.text
    return body


@app.command("database-create")
def database_create(
    name: str = typer.Argument(...),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a SQL database (POST /dbs)."""
    resp = wire.cosmos_request("POST", "dbs", {"id": name})
    body = _cosmos(resp, (200, 201), f"database-create {name}")
    wire.emit({"id": body.get("id", name), "status": resp.status_code},
              output, title=f"database {name}")


@app.command("container-create")
def container_create(
    database: str = typer.Argument(...),
    container: str = typer.Argument(...),
    partition_key: str = typer.Option("/pk", "--partition-key"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a container (POST /dbs/:db/colls)."""
    resp = wire.cosmos_request("POST", f"dbs/{database}/colls",
                                {"id": container,
                                 "partitionKey": {"paths": [partition_key]}})
    body = _cosmos(resp, (200, 201), f"container-create {database}/{container}")
    wire.emit({"id": body.get("id", container), "status": resp.status_code},
              output, title=f"container {database}/{container}")


@app.command("doc-put")
def doc_put(
    database: str = typer.Argument(...),
    container: str = typer.Argument(...),
    doc_id: str = typer.Argument(...),
    body: str = typer.Argument(..., help="Doc JSON (must carry id + pk)."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a document (POST .../docs)."""
    try:
        doc = json.loads(body)
    except ValueError as e:
        wire.andon(f"doc-put invalid JSON body: {e}")
    doc.setdefault("id", doc_id)
    resp = wire.cosmos_request(
        "POST", f"dbs/{database}/colls/{container}/docs", doc,
        extra_headers=_pk_header(database, container, doc))
    out = _cosmos(resp, (200, 201), f"doc-put {doc_id}")
    wire.emit({"id": out.get("id", doc_id), "_etag": out.get("_etag", ""),
               "status": resp.status_code}, output, title=f"doc {doc_id}")


@app.command("doc-get")
def doc_get(
    database: str = typer.Argument(...),
    container: str = typer.Argument(...),
    doc_id: str = typer.Argument(...),
    output: str = typer.Option("json", "--output", "-o"),
) -> None:
    """Read a document (GET .../docs/:id)."""
    resp = wire.cosmos_request("GET", f"dbs/{database}/colls/{container}/docs/{doc_id}")
    out = _cosmos(resp, (200,), f"doc-get {doc_id}")
    wire.emit(out, output, title=f"doc {doc_id}")


@app.command("doc-replace")
def doc_replace(
    database: str = typer.Argument(...),
    container: str = typer.Argument(...),
    doc_id: str = typer.Argument(...),
    body: str = typer.Argument(..., help="Full replacement doc JSON."),
    if_match: str = typer.Option("", "--if-match", help="ETag for CAS."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Replace a document with If-Match ETag-CAS (stale etag -> ANDON 412)."""
    try:
        doc = json.loads(body)
    except ValueError as e:
        wire.andon(f"doc-replace invalid JSON body: {e}")
    doc.setdefault("id", doc_id)
    headers = {"If-Match": if_match} if if_match else {}
    headers.update(_pk_header(database, container, doc))
    resp = wire.cosmos_request("PUT", f"dbs/{database}/colls/{container}/docs/{doc_id}",
                                doc, extra_headers=headers)
    out = _cosmos(resp, (200,), f"doc-replace {doc_id}")
    wire.emit({"id": out.get("id", doc_id), "_etag": out.get("_etag", ""),
               "status": resp.status_code}, output, title=f"doc {doc_id}")


@app.command("doc-delete")
def doc_delete(
    database: str = typer.Argument(...),
    container: str = typer.Argument(...),
    doc_id: str = typer.Argument(...),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Delete a document (DELETE .../docs/:id)."""
    resp = wire.cosmos_request("DELETE", f"dbs/{database}/colls/{container}/docs/{doc_id}")
    _cosmos(resp, (200, 204), f"doc-delete {doc_id}")
    wire.emit({"id": doc_id, "deleted": True, "status": resp.status_code},
              output, title=f"doc {doc_id}")
