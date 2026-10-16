#!/usr/bin/env python3
"""PY-2 lane: real azure-storage-blob SDK probes against the smalt egress blob plane (8443).

Auth: SharedKey (account smaltacct / key smaltacct-key) via connection string,
mirroring test/sdk-smoke/blob.test.cjs. The immutable-policy opt-out
(x-ms-immutable-policy: false) is a substrate extension not exposed by the
Python SDK's create_container, so mutable-container creation uses the SDK
pipeline's raw send with a custom header (same pattern as the JS harness's
fetch() PUT).
"""
import base64
import sys
import time
import urllib.request

from azure.core.exceptions import (
    DeserializationError,
    HttpResponseError,
    ResourceExistsError,
    ResourceModifiedError,
)
from azure.storage.blob import BlobServiceClient

BASE = "http://127.0.0.1:8443"
ACCOUNT = "smaltacct"
KEY = "smaltacct-key"  # substrate accepts any non-empty key value in anonymous mode

CONN = (
    f"DefaultEndpointsProtocol=http;AccountName={ACCOUNT};"
    f"AccountKey={base64.b64encode(KEY.encode()).decode()};"
    f"BlobEndpoint={BASE}/{ACCOUNT};"
)

results = []


def probe(name, fn):
    try:
        detail = fn()
        results.append((name, "PASS", detail or ""))
        print(f"PASS {name} :: {detail or ''}")
    except AssertionError as e:
        results.append((name, "FAIL", str(e)))
        print(f"FAIL {name} :: {e}")
    except Exception as e:
        results.append((name, "ERROR", f"{type(e).__name__}: {e}"))
        print(f"ERROR {name} :: {type(e).__name__}: {e}")


def service():
    return BlobServiceClient.from_connection_string(CONN)


def raw_put(url, headers):
    req = urllib.request.Request(url, method="PUT", headers=headers, data=b"")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def make_mutable_container(name):
    """Create a WORM-opt-out container via the raw header the substrate defines."""
    st = raw_put(
        f"{BASE}/{ACCOUNT}/{name}",
        {
            "x-ms-version": "2021-04-01",
            "x-ms-immutable-policy": "false",
        },
    )
    assert st == 201, f"mutable container create expected 201, got {st}"
    return service().get_container_client(name)


def p01_create_default_immutable():
    c = service().get_container_client(f"py-imm-{int(time.time()*1000)}")
    c.create_container()  # 201; verified by subsequent upload probes
    return f"created {c.container_name}"


def p02_create_mutable_optout():
    c = make_mutable_container(f"py-mut-{int(time.time()*1000)}")
    return f"created opt-out {c.container_name}"


def p03_upload_download():
    c = make_mutable_container(f"py-up-{int(time.time()*1000)}")
    blob = c.get_blob_client("greeting.txt")
    content = "héllo smalt — multibyte 🌊 content".encode("utf-8")
    resp = blob.upload_blob(content, overwrite=True)
    got = blob.download_blob().readall()
    assert got == content, f"roundtrip mismatch: {got!r}"
    return f"etag={resp['etag']}, {len(content)} bytes roundtrip"


def p04_set_get_metadata():
    c = make_mutable_container(f"py-meta-{int(time.time()*1000)}")
    blob = c.get_blob_client("m.bin")
    blob.upload_blob(b"data", overwrite=True)
    try:
        blob.set_blob_metadata({"pylane": "two", "env": "sdk"})
    except HttpResponseError as e:
        if e.status_code == 201:
            raise AssertionError(
                "DIVERGENCE: Set Blob Metadata returned 201 Created; spec/Azure returns 200 OK "
                "(azure-storage-blob 12.31.0 rejects the 201)"
            )
        raise
    md = blob.get_blob_properties().metadata
    assert md.get("pylane") == "two" and md.get("env") == "sdk", f"metadata mismatch: {md}"
    return f"metadata echoed: {md}"


def p05_list_delimiter_metadata():
    c = make_mutable_container(f"py-list-{int(time.time()*1000)}")
    for name in ("a/x.txt", "a/y.txt", "b/z.txt", "top.txt"):
        c.get_blob_client(name).upload_blob(b"v", overwrite=True)
    c.get_blob_client("a/x.txt").upload_blob(b"v", overwrite=True, metadata={"tag": "ax"})
    try:
        walk = c.walk_blobs(name_starts_with="", delimiter="/")
        prefixes = sorted(w.prefix for w in walk if hasattr(w, "prefix"))
        assert prefixes == ["a/", "b/"], f"virtual dirs: {prefixes}"
        listed = list(c.list_blobs(name_starts_with="a/", include=["metadata"]))
        md = [b.metadata.get("tag") for b in listed if b.name == "a/x.txt"]
        assert md == ["ax"], f"metadata in listing: {md}"
        page = list(c.list_blobs(name_starts_with="", results_per_page=2).by_page())[0]
        assert len(list(page)) == 2, "results_per_page=2 returned != 2"
        return f"prefixes={prefixes}, include=metadata ok, page-size ok"
    except DeserializationError as e:
        raise AssertionError(
            f"DIVERGENCE: List Blobs XML undeserializable by azure-storage-blob 12.31.0 "
            f"(BlobProperties missing required fields — BlobType/LeaseStatus/Content-Type — "
            f"and Last-Modified emitted ISO-8601, not RFC-1123): {e}"
        )


def p06_list_junk_maxresults_400():
    c = make_mutable_container(f"py-junk-{int(time.time()*1000)}")
    c.get_blob_client("j.txt").upload_blob(b"j", overwrite=True)
    try:
        list(c.list_blobs(results_per_page=-7))
        raise AssertionError("junk maxresults accepted (expected 400)")
    except HttpResponseError as e:
        assert e.status_code == 400, f"expected 400, got {e.status_code}: {e.message}"
        return f"400 as expected ({(e.message or '')[:60]})"


def p07_if_match_412():
    c = make_mutable_container(f"py-cond-{int(time.time()*1000)}")
    blob = c.get_blob_client("c.bin")
    blob.upload_blob(b"v1", overwrite=True)
    stale_etag = blob.get_blob_properties().etag
    blob.upload_blob(b"v2", overwrite=True)  # etag now differs
    from azure.core import MatchConditions

    try:
        blob.download_blob(etag=stale_etag, match_condition=MatchConditions.IfNotModified)
        raise AssertionError("stale If-Match download succeeded (expected 412)")
    except HttpResponseError as e:
        assert e.status_code == 412, f"expected 412, got {e.status_code}"
        return f"412 on stale etag {stale_etag}"


def p08_delete_202():
    c = make_mutable_container(f"py-del-{int(time.time()*1000)}")
    blob = c.get_blob_client("d.txt")
    blob.upload_blob(b"bye", overwrite=True)
    blob.delete_blob()
    assert not blob.exists(), "blob should be gone after delete"
    return "delete 202, exists() false"


def p09_immutable_overwrite_409():
    c = service().get_container_client(f"py-worm-{int(time.time()*1000)}")
    c.create_container()  # default = immutable (WORM)
    blob = c.get_blob_client("locked.bin")
    blob.upload_blob(b"first", overwrite=True)
    try:
        blob.upload_blob(b"second", overwrite=True)
        raise AssertionError("immutable overwrite succeeded (expected 409 ContainerLocked)")
    except HttpResponseError as e:
        code = getattr(e, "error_code", None) or (
            e.response.headers.get("x-ms-error-code") if e.response is not None else None
        )
        assert e.status_code == 409, f"expected 409, got {e.status_code}"
        assert code == "ContainerLocked", f"expected ContainerLocked, got {code!r}"
        return f"409 ContainerLocked as expected"


def p10_get_container_properties_rfc1123():
    """Divergence probe: spec requires RFC-1123 Last-Modified; substrate emits ISO-8601."""
    c = make_mutable_container(f"py-props-{int(time.time()*1000)}")
    try:
        p = c.get_container_properties()
        return f"last_modified={p.last_modified!r} (RFC-1123 OK)"
    except DeserializationError as e:
        raise AssertionError(
            f"DIVERGENCE: Get Container Properties Last-Modified not RFC-1123 "
            f"(SDK DeserializationError: {e})"
        )


probe("01 create container default-immutable", p01_create_default_immutable)
probe("02 create container mutable opt-out (x-ms-immutable-policy: false)", p02_create_mutable_optout)
probe("03 upload/download block blob roundtrip", p03_upload_download)
probe("04 set/get blob metadata", p04_set_get_metadata)
probe("05 list: delimiter + include=metadata + results_per_page", p05_list_delimiter_metadata)
probe("06 list junk maxresults -> 400", p06_list_junk_maxresults_400)
probe("07 conditional If-Match stale etag -> 412", p07_if_match_412)
probe("08 delete blob -> 202", p08_delete_202)
probe("09 immutable overwrite -> 409 ContainerLocked", p09_immutable_overwrite_409)
probe("10 get container properties (RFC-1123 Last-Modified)", p10_get_container_properties_rfc1123)

fails = [r for r in results if r[1] != "PASS"]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
