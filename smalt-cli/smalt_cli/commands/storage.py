"""storage sub-app: blob container create/list + BlockBlob upload.

Wire face: egress data plane PUT /smaltacct/{container}/{blob}
(x-ms-blob-type: BlockBlob), real etag surfaced; non-201 is an ANDON refusal.

Auth: every wire call runs the KD-15 challenge handshake (tokenless first
touch -> 401 -> bearer retry), so the storage group works against :enforce
substrates exactly like cosmos/kv (EXPL12-2).
"""
from __future__ import annotations

import re

import httpx
import typer

from .. import wire

app = typer.Typer(help="Blob storage (egress data plane :8443).")


def _blob_request(method: str, url: str, *, content: bytes | None = None,
                  headers: dict | None = None,
                  params: dict | None = None) -> httpx.Response:
    """Blob wire call with the KD-15 challenge handshake: tokenless first
    touch takes the 401, then one bearer retry (mirrors wire.kv_request /
    wire.cosmos_request; corpus premise pin)."""
    hdrs = dict(headers or {})
    resp = httpx.request(method, url, content=content, params=params,
                         headers=hdrs, verify=False, timeout=30.0)
    if resp.status_code == 401:
        auth = wire.bearer_for_arm()
        if auth:
            hdrs.update(auth)
            resp = httpx.request(method, url, content=content, params=params,
                                 headers=hdrs, verify=False, timeout=30.0)
    return resp


def _container_put_headers(immutable: bool) -> dict:
    """KD-135 Azure-parity shape: a container is writable unless explicitly
    created immutable. --immutable sends x-ms-immutable-policy: true (opt IN
    to WORM); --no-immutable sends the explicit-false form."""
    return {
        "x-ms-version": wire.XMS_VERSION,
        "x-ms-immutable-policy": "true" if immutable else "false",
    }


@app.command("container-create")
def container_create(
    container: str = typer.Argument(..., help="Container name."),
    immutable: bool = typer.Option(
        False, "--immutable/--no-immutable",
        help="WORM/immutable container, OPT-IN (post-KD-135 substrate default "
             "is writable; absent header == writable). --no-immutable sends "
             "the explicit-false form.",
    ),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a blob container."""
    resp = _blob_request(
        "PUT", wire.blob_url(container),
        headers=_container_put_headers(immutable),
    )
    if resp.status_code != 201:
        wire.andon(f"container-create {container}", status=resp.status_code)
    wire.emit(
        {"container": container, "status": resp.status_code,
         "immutable": immutable,
         "etag": resp.headers.get("ETag", "")},
        output, title=f"container {container}",
    )


@app.command("container-list")
def container_list(output: str = typer.Option("table", "--output", "-o")) -> None:
    """List blob containers on the smaltacct account."""
    resp = _blob_request(
        "GET", f"{wire.egress_endpoint()}/smaltacct",
        params={"comp": "list"},
        headers={"x-ms-version": wire.XMS_VERSION},
    )
    if resp.status_code != 200:
        wire.andon("container-list", status=resp.status_code)
    names = re.findall(r"<Name>([^<]+)</Name>", resp.text)
    wire.emit([{"name": n} for n in names], output, title="containers")


@app.command("blob-upload")
def blob_upload(
    container: str = typer.Argument(...),
    blob: str = typer.Argument(...),
    data: str = typer.Argument(..., help="Payload string (utf-8)."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Upload a BlockBlob; ANDON refusal on anything but 201.

    Output surfaces the real response ETag + status.
    """
    resp = _blob_request(
        "PUT", wire.blob_url(container, blob),
        content=data.encode("utf-8"),
        headers={
            "x-ms-blob-type": "BlockBlob",
            "x-ms-version": wire.XMS_VERSION,
        },
    )
    if resp.status_code != 201:
        wire.andon(f"blob-upload {container}/{blob}", status=resp.status_code)
    etag = resp.headers.get("ETag", "")
    wire.emit(
        {"container": container, "blob": blob, "status": resp.status_code,
         "etag": etag},
        output, title=f"blob {container}/{blob}",
    )
