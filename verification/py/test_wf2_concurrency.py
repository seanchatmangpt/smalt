"""WF2 — concurrency + conditional-write races (real wire).

- 8 concurrent cosmos replace_item with the SAME if_match etag (asyncio.gather
  over a real thread pool — azure-cosmos is a sync SDK): exactly one 200, 7 x
  412 CosmosAccessConditionFailedError, winner identity confirmed by readback.
- App Configuration /kv If-Match race: exactly one 200; unconditional
  overwrite of an existing kv -> 409 WriteConflict.
- Blob WORM legal hold: create -> upload -> hold on -> overwrite/delete
  refused 409 ContainerLocked -> hold off -> delete OK.
"""
import asyncio
import secrets
from concurrent.futures import ThreadPoolExecutor

import pytest
import requests
import azure.cosmos.cosmos_client as cc
from azure.cosmos import exceptions as cosmosex
from azure.core.exceptions import HttpResponseError
from azure.storage.blob import BlobServiceClient

pytestmark = pytest.mark.enforce

RUN = "pywf2"
TOK = {"Authorization": "Bearer pywf2-anonymous-leg"}  # anonymous-mode leg


# ---------------------------------------------------------------------------
# Cosmos etag race
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_cosmos_etag_race(anon_substrate):
    egress = anon_substrate["egress"]
    client = cc.CosmosClient(egress, credential=secrets.token_hex(32))
    db = client.create_database(f"{RUN}-{secrets.token_hex(4)}")
    cont = db.create_container(id="c1", partition_key="/pk")
    doc = cont.create_item({"id": "racer", "pk": "p", "n": 0})
    etag = doc["_etag"]

    loop = asyncio.get_running_loop()
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = await asyncio.gather(*[
            loop.run_in_executor(pool, _replace_with_etag, cont, etag, i)
            for i in range(8)
        ])

    winners = [r for r in results if not isinstance(r, Exception)]
    losers = [r for r in results if isinstance(r, cosmosex.CosmosAccessConditionFailedError)]
    assert len(winners) == 1, f"expected exactly one CAS winner, got {winners!r}"
    assert len(losers) == 7, (
        f"expected 7 x CosmosAccessConditionFailedError, got "
        f"{[type(r).__name__ for r in results]}"
    )
    for l in losers:
        assert l.status_code == 412, f"loser status {l.status_code}"

    winner_n = winners[0]
    back = cont.read_item("racer", partition_key="p")
    assert back["n"] == winner_n, f"winner identity lost: readback={back['n']} winner={winner_n}"
    assert back["_etag"] != etag, "etag did not rotate on the winning write"


def _replace_with_etag(cont, etag, n):
    from azure.core import MatchConditions

    try:
        cont.replace_item(
            "racer", body={"id": "racer", "pk": "p", "n": n},
            etag=etag, match_condition=MatchConditions.IfNotModified,
        )
        return n
    except cosmosex.CosmosAccessConditionFailedError as e:
        return e


# ---------------------------------------------------------------------------
# App Configuration /kv race
# ---------------------------------------------------------------------------


def _kv_url(egress, key):
    return f"{egress}/kv/{key}?api-version=1.0"


def _kv_put(egress, key, value, if_match=None, if_none_match=None, extra=None):
    headers = {"Content-Type": "application/json"}
    headers.update(extra or {})
    if if_match:
        headers["If-Match"] = if_match
    if if_none_match:
        headers["If-None-Match"] = if_none_match
    return requests.put(
        _kv_url(egress, key), json={"value": value}, headers=headers, timeout=15
    )


@pytest.mark.asyncio
async def test_appconfig_race_and_write_conflict(anon_substrate):
    egress = anon_substrate["egress"]
    key = f"{RUN}-{secrets.token_hex(3)}"

    # KD-15 challenge handshake (mode-blind): tokenless first touch -> 401 ->
    # resend bearing a token (anonymous mode admits any bearer value).
    first = requests.get(_kv_url(egress, key), timeout=10)
    assert first.status_code == 401, f"expected 401 challenge, got {first.status_code}"
    assert first.headers.get("WWW-Authenticate", "").startswith("Bearer"), (
        "missing WWW-Authenticate challenge"
    )

    created = _kv_put(egress, key, "v0", if_none_match="*", extra=TOK)
    assert created.status_code == 201, created.text[:200]
    etag = created.json()["etag"]

    loop = asyncio.get_running_loop()
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = await asyncio.gather(*[
            loop.run_in_executor(pool, _kv_put, egress, key, f"v{i}", etag, None, TOK)
            for i in range(1, 7)
        ])
    ok = [r for r in results if r.status_code == 200]
    stale = [r for r in results if r.status_code == 412]
    assert len(ok) == 1, f"expected one CAS winner, got {[r.status_code for r in results]}"
    assert len(stale) == 5, f"expected 5 x 412, got {[r.status_code for r in results]}"

    # Unconditional overwrite of an existing kv -> 409 WriteConflict.
    conflict = _kv_put(egress, key, "vX", extra=TOK)
    assert conflict.status_code == 409, conflict.text[:200]
    assert conflict.json()["error"]["code"] == "WriteConflict", conflict.text[:200]

    # The winner's value is what survives.
    back = requests.get(_kv_url(egress, key), headers=TOK, timeout=10)
    assert back.json()["value"] in {f"v{i}" for i in range(1, 7)}


# ---------------------------------------------------------------------------
# Blob WORM legal hold
# ---------------------------------------------------------------------------


def _legalhold(egress, container, flag):
    return requests.put(
        f"{egress}/smaltacct/{container}?restype=container&comp=legalhold",
        headers={"x-ms-legal-hold": "true" if flag else "false",
                 "x-ms-version": "2021-04-01"},
        timeout=15,
    )


def test_blob_legal_hold(anon_substrate):
    """WORM legal hold: azure-storage-blob python exposes NO legal-hold
    methods (recorded SDK gap), so comp=legalhold rides raw requests over the
    same real wire; blob create/overwrite/delete use the real SDK."""
    egress = anon_substrate["egress"]
    key = secrets.token_hex(32)
    conn = (
        f"DefaultEndpointsProtocol=http;AccountName=smaltacct;"
        f"AccountKey={key};BlobEndpoint={egress}/smaltacct;"
    )
    svc = BlobServiceClient.from_connection_string(conn, retry_total=0)
    cont = svc.get_container_client(f"{RUN}-worm-{secrets.token_hex(3)}")
    cont.create_container()
    blob = cont.get_blob_client("held-blob")
    blob.upload_blob(b"payload-v1", overwrite=True)

    r = _legalhold(egress, cont.container_name, True)
    assert r.status_code == 200, f"legalhold on -> {r.status_code} {r.text[:150]}"

    try:
        blob.upload_blob(b"payload-v2", overwrite=True)
        raise AssertionError("overwrite under legal hold admitted — expected 409 ContainerLocked")
    except HttpResponseError as e:
        assert e.status_code == 409, f"expected 409, got {e.status_code}"
        assert "ContainerLocked" in str(e), f"expected ContainerLocked, got {str(e)[:200]}"
    try:
        blob.delete_blob()
        raise AssertionError("delete under legal hold admitted — expected 409 ContainerLocked")
    except HttpResponseError as e:
        assert e.status_code == 409 and "ContainerLocked" in str(e), str(e)[:200]

    r = _legalhold(egress, cont.container_name, False)
    assert r.status_code == 200, f"legalhold off -> {r.status_code} {r.text[:150]}"
    cont.delete_blob("held-blob")  # 202 accepted
    assert not blob.exists(), "blob survived legal-hold-cleared delete"
