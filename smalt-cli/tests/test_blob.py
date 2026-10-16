"""CLI-4 blob lane: container create (incl. immutable), upload/download,
409 overwrite-on-immutable, 412 stale If-Match, junk maxresults 400.

Mirrors test/sdk-python/py_storage_blob.py against the egress blob plane.
"""
import time
import urllib.error
import urllib.request

import pytest
from azure.core import MatchConditions
from azure.core.exceptions import HttpResponseError
from azure.storage.blob import BlobServiceClient

from conftest import EGRESS, blob_conn_string


def service():
    return BlobServiceClient.from_connection_string(blob_conn_string())


def raw_put_container(name, headers):
    req = urllib.request.Request(f"{EGRESS}/smaltacct/{name}", method="PUT",
                                 data=b"", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def make_mutable_container(name):
    st = raw_put_container(name, {"x-ms-version": "2021-04-01",
                                  "x-ms-immutable-policy": "false"})
    assert st == 201, f"mutable container create expected 201, got {st}"
    return service().get_container_client(name)


UNIQ = int(time.time() * 1000)


def test_container_create_default_immutable():
    # Default (no opt-out header) containers are WORM/immutable: admission is
    # proven by the subsequent upload succeeding and overwrite 409-ing (see
    # test_immutable_overwrite_409_container_locked). Get Container Properties
    # is deliberately NOT probed here: the substrate emits ISO-8601
    # Last-Modified where azure-storage-blob 12.31.0 requires RFC-1123 — a
    # documented divergence (test/sdk-python/py_storage_blob.py p10).
    c = service().get_container_client(f"cli4-imm-{UNIQ}")
    c.create_container()
    blob = c.get_blob_client("admit.bin")
    blob.upload_blob(b"ok", overwrite=True)
    assert blob.download_blob().readall() == b"ok"


def test_container_create_mutable_optout():
    c = make_mutable_container(f"cli4-mut-{UNIQ}")
    assert c.container_name == f"cli4-mut-{UNIQ}"


def test_upload_download_roundtrip():
    c = make_mutable_container(f"cli4-up-{UNIQ}")
    blob = c.get_blob_client("greeting.txt")
    content = "héllo smalt — multibyte 🌊 content".encode()
    resp = blob.upload_blob(content, overwrite=True)
    got = blob.download_blob().readall()
    assert got == content
    assert resp["etag"]


def test_immutable_overwrite_409_container_locked():
    c = service().get_container_client(f"cli4-worm-{UNIQ}")
    c.create_container()  # default = immutable (WORM)
    blob = c.get_blob_client("locked.bin")
    blob.upload_blob(b"first", overwrite=True)
    with pytest.raises(HttpResponseError) as ei:
        blob.upload_blob(b"second", overwrite=True)
    e = ei.value
    code = getattr(e, "error_code", None) or (
        e.response.headers.get("x-ms-error-code") if e.response is not None else None)
    assert e.status_code == 409, e.status_code
    assert code == "ContainerLocked", code


def test_stale_if_match_412():
    c = make_mutable_container(f"cli4-cond-{UNIQ}")
    blob = c.get_blob_client("c.bin")
    blob.upload_blob(b"v1", overwrite=True)
    stale_etag = blob.get_blob_properties().etag
    blob.upload_blob(b"v2", overwrite=True)  # rotates etag
    with pytest.raises(HttpResponseError) as ei:
        blob.download_blob(etag=stale_etag, match_condition=MatchConditions.IfNotModified)
    assert ei.value.status_code == 412, ei.value.status_code


def test_junk_maxresults_400():
    c = make_mutable_container(f"cli4-junk-{UNIQ}")
    c.get_blob_client("j.txt").upload_blob(b"j", overwrite=True)
    with pytest.raises(HttpResponseError) as ei:
        list(c.list_blobs(results_per_page=-7))
    assert ei.value.status_code == 400, ei.value.status_code
