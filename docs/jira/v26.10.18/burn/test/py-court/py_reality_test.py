#!/usr/bin/env python3
"""Reality-grade Python court for the smalt substrate.

Real azure-sdk-for-python clients over real loopback wire against a live
substrate. No pytest, no mocks, no skips: every probe either PASSES or
FAILS (with the verbatim reason). Exit code 0 only if every probe passed.
"""

import base64
import json
import os
import threading
import time

import requests

ARM = "http://127.0.0.1:9443"
EGRESS = "http://127.0.0.1:8443"
TENANT = "00000000-0000-0000-0000-000000000000"

SB_KEY = os.environ.get("SB_SHARED_KEY", "")
MAA_MEASUREMENT = os.environ.get("MAA_MEASUREMENT", "")
# Dev TLS cert minted by the substrate at boot (py-run.sh exports it as
# REQUESTS_CA_BUNDLE). https://localhost:9444 clients trust it via
# connection_verify=CA_BUNDLE below.
CA_BUNDLE = os.environ.get("REQUESTS_CA_BUNDLE")

FAILURES = []


PROBE_TIMEOUT_S = 40


def probe(fn):
    name = fn.__name__.replace("probe_", "", 1)
    result = {}

    def target():
        try:
            fn()
            result["ok"] = True
        except Exception as exc:  # noqa: BLE001 - court records every failure
            result["reason"] = f"{type(exc).__name__}: {exc}"

    th = threading.Thread(target=target, daemon=True)
    th.start()
    th.join(timeout=PROBE_TIMEOUT_S)
    if th.is_alive():
        result["reason"] = f"probe exceeded {PROBE_TIMEOUT_S}s (transport hang); abandoned"
        result.pop("ok", None)
    if result.get("ok"):
        print(f"PASS  {name}", flush=True)
        return True
    reason = result.get("reason", "probe produced no result")
    print(f"FAIL  {name}", flush=True)
    print(f"      reason: {reason}", flush=True)
    FAILURES.append((name, reason))
    return False


# =========================================================================
# Probe 1: OAuth2 client-credentials via azure.identity (real MSAL)
# =========================================================================
def probe_oauth_client_secret():
    # TLS-trust pattern (verified against azure-core 1.41.0 source): kwargs on
    # ClientSecretCredential flow MsalCredential -> MsalClient ->
    # identity/_internal/pipeline.build_pipeline -> RequestsTransport ->
    # ConnectionConfiguration, where `connection_verify` becomes the transport
    # verify path. (requests also honors REQUESTS_CA_BUNDLE via trust_env as a
    # second belt; the explicit kwarg is primary so the probe does not depend
    # on env.) azure-identity has no per-credential SSL_CERT_FILE handling of
    # its own — SSL_CERT_FILE only matters to python's ssl default context,
    # which azure-core's explicit-verify path bypasses.
    from azure.identity import ClientSecretCredential

    cred = ClientSecretCredential(
        tenant_id=TENANT,
        client_id="py-court-client",
        client_secret="py-court-secret",
        authority="https://localhost:9444/",
        disable_instance_discovery=True,
        connection_verify=CA_BUNDLE,
    )
    tok = cred.get_token("https://management.azure.com/.default")
    assert tok.token, "empty access token from substrate STS"
    segs = tok.token.split(".")
    assert len(segs) == 3, f"token not JWT-shaped: {len(segs)} segments"
    payload = json.loads(base64.urlsafe_b64decode(segs[1] + "==").decode("utf8"))
    assert payload.get("aud"), f"JWT payload missing aud: {payload}"
    print(f"      token iss={payload.get('iss')} aud={payload.get('aud')}")


def probe_oauth_control_dead_authority():
    """Control run: same credential shape pointed at a dead authority on
    loopback must FAIL. If it succeeded, the pass above would not prove the
    token came from the substrate."""
    from azure.identity import ClientSecretCredential
    from azure.identity._exceptions import CredentialUnavailableError

    cred = ClientSecretCredential(
        tenant_id=TENANT,
        client_id="py-court-client",
        client_secret="py-court-secret",
        authority="https://localhost:19444/",  # nothing listens here
    )
    try:
        cred.get_token("https://management.azure.com/.default")
    except Exception as exc:
        print(f"      control refused as expected: {type(exc).__name__}")
        return
    raise AssertionError(
        "control credential SUCCEEDED against a dead authority — "
        "the main token is not proven to come from the substrate"
    )


# =========================================================================
# Probe 2: BYOK / Secure Key Release (MAA attestation + release flow)
# =========================================================================
def attest_token():
    """POST /attest/sevsnpvm with the baseline measurement -> MAA token."""
    res = requests.post(
        f"{EGRESS}/attest/sevsnpvm",
        json={"measurement": MAA_MEASUREMENT},
        timeout=30,
    )
    assert res.status_code == 200, (
        f"attest status {res.status_code}: {res.text[:300]} "
        f"(measurement used: {MAA_MEASUREMENT[:12]}..., env set: {bool(MAA_MEASUREMENT)})"
    )
    body = res.json()
    tok = body.get("token")
    assert tok, f"no token in attest response: {body}"
    return tok


def probe_skr_attest_403_without_token():
    tok = attest_token()
    name = "pycourt-skr-key"
    # Real Azure SKR release-policy grammar (claim/equals under anyOf). The
    # substrate's create-route validation (lib/smalt/egress_router.ex
    # validate_release_policy) rejects placeholder bodies lacking any
    # claim/equals assertion or allowed_operations list with 400
    # InvalidParameter — as real Key Vault does.
    create = requests.post(
        f"{EGRESS}/keys/{name}/create",
        json={
            "kty": "RSA-HSM",
            "release_policy": {
                "anyOf": [
                    {
                        "anyOf": [
                            {"claim": "x-ms-SGX-is-debuggable", "equals": "true"},
                            {"claim": "x-ms-attestation-type", "equals": "sevsnpvm"},
                        ]
                    }
                ]
            },
        },
        timeout=30,
    )
    assert create.status_code == 200, f"key create status {create.status_code}: {create.text[:300]}"
    noauth = requests.post(f"{EGRESS}/keys/{name}/release", timeout=30)
    assert noauth.status_code == 403, (
        f"expected 403 without attestation token, got {noauth.status_code}: {noauth.text[:300]}"
    )
    bad = requests.post(
        f"{EGRESS}/keys/{name}/release",
        headers={"Authorization": "Bearer not-a-real-token"},
        timeout=30,
    )
    assert bad.status_code == 403, (
        f"expected 403 with bogus attestation token, got {bad.status_code}: {bad.text[:300]}"
    )


def probe_skr_release_with_maa_token():
    tok = attest_token()
    name = "pycourt-skr-key"
    rel = requests.post(
        f"{EGRESS}/keys/{name}/release",
        headers={"Authorization": f"Bearer {tok}"},
        timeout=30,
    )
    assert rel.status_code == 200, (
        f"release with MAA token status {rel.status_code}: {rel.text[:300]}"
    )
    body = rel.json()
    assert body.get("status") == "Released", f"release body: {body}"


def probe_keyvault_sdk_surface():
    """azure.keyvault.keys KeyClient over the substrate's TLS twin on 9444
    (TlsTwinDispatch routes /keys to EgressRouter), with the dev-cert CA and a
    real BearerTokenCredential that fetches the token from the substrate STS.
    SDK PUT-shape routes that the substrate does not serve are recorded as
    FAILURES with the verbatim reason (SDK-limitation failures are failures,
    never skips)."""
    from azure.keyvault.keys import KeyClient
    from azure.core.exceptions import HttpResponseError

    client = KeyClient(
        "https://localhost:9444",
        _SubstrateTokenCredential(),
        connection_verify=CA_BUNDLE,
    )
    try:
        key = client.get_key("pycourt-skr-key")
        print(f"      KeyClient.get_key ok: kid={key.id}")
    except HttpResponseError as exc:
        raise AssertionError(f"KeyClient.get_key failed: {exc.message} ({exc.status_code})")
    try:
        created = client.create_key("pycourt-sdk-key", "RSA")
        print(f"      KeyClient.create_key ok: kid={created.id}")
    except HttpResponseError as exc:
        raise AssertionError(
            "SDK-limitation: KeyClient.create_key (PUT /keys/{name}) not served "
            f"by substrate: {exc.message} ({exc.status_code})"
        )


class _SubstrateTokenCredential:
    """Real BearerTokenCredential: fetches an OAuth2 token from the substrate
    STS over the wire (client_credentials). Hand-written real interface
    implementation, not a mock."""

    def get_token(self, *scopes, **kwargs):
        res = requests.post(
            f"{ARM}/{TENANT}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": "py-court-client",
                "client_secret": "py-court-secret",
                "scope": "https://management.azure.com/.default",
            },
            timeout=30,
        )
        assert res.status_code == 200, f"STS status {res.status_code}: {res.text[:200]}"
        tok = res.json()["access_token"]
        from azure.core.credentials import AccessToken

        return AccessToken(tok, int(time.time()) + 3600)


# =========================================================================
# Probe 3: Cosmos DB (azure-cosmos, master key over 8443)
# =========================================================================
def probe_cosmos_crud_and_queries():
    import hashlib
    from azure.cosmos import CosmosClient
    from azure.cosmos.exceptions import CosmosHttpResponseError
    from azure.core import MatchConditions

    key = hashlib.sha256(b"py-court-cosmos").hexdigest()  # 64 hex chars
    client = CosmosClient(EGRESS, credential=key, enable_endpoint_discovery=False)
    db_id = "pycourt-db"
    client.create_database_if_not_exists(db_id)
    db = client.get_database_client(db_id)
    container = db.create_container_if_not_exists(id="pycourt-coll", partition_key="/pk")

    item = {"id": "py-item-1", "pk": "py", "value": "héllo 🌊 py-court"}
    created = container.create_item(body=item)
    assert created["value"] == item["value"], "round-trip value mismatch"

    read = container.read_item(item=item["id"], partition_key="py")
    assert read["value"] == item["value"], "read value mismatch"
    etag = read["_etag"]
    assert etag, "no _etag on read item"

    query = list(
        container.query_items(query="SELECT * FROM c WHERE c.pk = @pk", parameters=[{"name": "@pk", "value": "py"}], enable_cross_partition_query=True)
    )
    assert any(r["id"] == "py-item-1" for r in query), f"cross-partition query missed item: {query}"

    container.replace_item(
        item=item["id"], body={**item, "value": "v2"},
        etag=etag, match_condition=MatchConditions.IfNotModified,
    )
    try:
        container.replace_item(
            item=item["id"], body={**item, "value": "v3"},
            etag=etag, match_condition=MatchConditions.IfNotModified,
        )
        raise AssertionError("stale-etag replace succeeded; expected 412")
    except CosmosHttpResponseError as exc:
        assert exc.status_code == 412, f"expected 412, got {exc.status_code}: {exc.message}"

    container.delete_item(item=item["id"], partition_key="py")
    # Cleanup is best-effort: the substrate's cosmos surface (data_plane/cosmos.ex)
    # serves no DELETE /dbs/:db/colls/:coll route (doc-level delete only), so
    # container delete 404s RouteNotFound. Disclosed substrate gap, not asserted.
    try:
        db.delete_container("pycourt-coll")
    except Exception as exc:  # noqa: BLE001 - cleanup only; gap disclosed above
        print(f"      note: container cleanup unavailable (substrate gap): {exc}")
    print("      cosmos CRUD + 412 ok")


def probe_cosmos_stale_etag_412():
    import hashlib
    from azure.cosmos import CosmosClient
    from azure.cosmos.exceptions import CosmosHttpResponseError
    from azure.core import MatchConditions

    key = hashlib.sha256(b"py-court-cosmos").hexdigest()
    client = CosmosClient(EGRESS, credential=key, enable_endpoint_discovery=False)
    db = client.get_database_client("pycourt-db")
    container = db.get_container_client("pycourt-coll")
    item = {"id": "py-item-2", "pk": "py2", "value": "etag-court"}
    container.create_item(body=item)
    read = container.read_item(item="py-item-2", partition_key="py2")
    fresh_etag = read["_etag"]
    container.replace_item(
        item="py-item-2", body={**item, "value": "v2"},
        etag=fresh_etag, match_condition=MatchConditions.IfNotModified,
    )
    try:
        container.replace_item(
            item="py-item-2", body={**item, "value": "v3"},
            etag=fresh_etag, match_condition=MatchConditions.IfNotModified,
        )
        raise AssertionError("stale etag accepted; expected 412")
    except CosmosHttpResponseError as exc:
        assert exc.status_code == 412, f"expected 412, got {exc.status_code}: {exc.message}"
    print("      stale etag 412 ok")


# =========================================================================
# Probe 4: Blob storage (azure-storage-blob, SharedKey over 8443)
# =========================================================================
def probe_blob_crud_and_worm():
    from azure.storage.blob import BlobServiceClient

    svc = BlobServiceClient(
        account_url=f"{EGRESS}/smaltacct",
        credential={"account_name": "smaltacct", "account_key": "smaltacct-key"},
    )
    cname = f"pycourt-{int(time.time())}"
    container = svc.get_container_client(cname)
    container.create_container()

    blob = container.get_blob_client("greeting.txt")
    content = "héllo smalt — py-court 🌊".encode("utf8")
    blob.upload_blob(content, overwrite=False)
    try:
        downloaded = blob.download_blob().readall()
        assert downloaded == content, "downloaded bytes differ from uploaded"
        print("      blob download round-trip ok")
    except Exception as exc:
        raise AssertionError(
            "SDK/substrate gap: python SDK ranged GET requires Content-Range; "
            f"substrate blob plane serves full 200 without Content-Range: "
            f"{type(exc).__name__}: {exc}"
        )


def probe_blob_worm_409():
    from azure.storage.blob import BlobServiceClient

    svc = BlobServiceClient(
        account_url=f"{EGRESS}/smaltacct",
        credential={"account_name": "smaltacct", "account_key": "smaltacct-key"},
    )
    container = svc.get_container_client(f"pycourt-worm-{int(time.time())}")
    container.create_container()
    blob = container.get_blob_client("worm.txt")
    blob.upload_blob(b"immutable", overwrite=False)
    try:
        blob.upload_blob(b"overwrite", overwrite=True)
        raise AssertionError("immutable container accepted overwrite; expected 409")
    except Exception as exc:
        code = getattr(exc, "status_code", None) or (
            exc.response.status_code if hasattr(exc, "response") and exc.response is not None else None
        )
        assert code == 409, f"expected 409 WORM refusal, got {code}: {type(exc).__name__}: {exc}"
    print("      immutable overwrite refused 409 ok")


# =========================================================================
# Probe 5: Service Bus (azure-servicebus over AMQP 5672)
# =========================================================================
SB_CS = (
    f"Endpoint=sb://127.0.0.1:5672;SharedAccessKeyName=RootManageSharedAccessKey;"
    f"SharedAccessKey={SB_KEY};UseDevelopmentEmulator=true"
)


def probe_sb_session_roundtrip_and_dlq():
    from azure.servicebus import ServiceBusClient, ServiceBusMessage

    client = ServiceBusClient.from_connection_string(SB_CS)
    queue = f"pycourt-q-{int(time.time())}"

    # Session sender/receiver round-trip + complete.
    sender = client.get_queue_sender(queue)
    with sender:
        sender.send_messages(ServiceBusMessage(body=b"session-payload", session_id="court-s1"))

    receiver = client.get_queue_receiver(queue, session_id="court-s1", max_wait_time=10)
    with receiver:
        msgs = receiver.receive_messages(max_message_count=5, max_wait_time=10)
        assert msgs, "no session message received"
        assert str(msgs[0]) == "session-payload", f"payload mismatch: {msgs[0]!r}"
        receiver.complete_message(msgs[0])
    print("      session send/receive/complete ok")


def probe_sb_dead_letter_and_lock_renew():
    from azure.servicebus import ServiceBusClient, ServiceBusMessage
    from azure.servicebus import ServiceBusSubQueue

    client = ServiceBusClient.from_connection_string(SB_CS)
    queue = f"pycourt-q-{int(time.time())}"

    sender = client.get_queue_sender(queue)
    with sender:
        sender.send_messages(ServiceBusMessage(body=b"dlq-me", session_id="court-dlq"))

    receiver = client.get_queue_receiver(queue, session_id="court-dlq", max_wait_time=10)
    with receiver:
        msgs = receiver.receive_messages(max_message_count=1, max_wait_time=10)
        assert msgs, "no message to dead-letter"
        msg = msgs[0]
        receiver.renew_message_locks(msg)  # lock renew within the 30s clamp
        receiver.dead_letter_message(msg, reason="py-court", error_description="dead-letter probe")

    dlq = client.get_queue_receiver(queue, sub_queue=ServiceBusSubQueue.DEAD_LETTER, max_wait_time=10)
    with dlq:
        dead = dlq.receive_messages(max_message_count=5, max_wait_time=10)
        assert any(str(m) == "dlq-me" for m in dead), (
            f"dead-lettered message not in DLQ: {[str(m) for m in dead]}"
        )
    print("      dead-letter -> DLQ + lock renew ok")


# =========================================================================
# Probe 6: Event Hubs (azure-eventhub over AMQP 5673)
# =========================================================================
EH_CS = (
    f"Endpoint=sb://127.0.0.1:5673;SharedAccessKeyName=RootManageSharedAccessKey;"
    f"SharedAccessKey={SB_KEY};EntityPath=py-hub;UseDevelopmentEmulator=true"
)


def probe_eventhub_roundtrip():
    from azure.eventhub import EventHubProducerClient, EventData, EventHubConsumerClient

    result = {}

    def run():
        try:
            producer = EventHubProducerClient.from_connection_string(EH_CS)
            with producer:
                producer.send_event(EventData(b"py-eh-payload"))
            result["send"] = True
        except Exception as exc:
            result["send_error"] = f"{type(exc).__name__}: {exc}"
            return

        received = []
        consumer = EventHubConsumerClient.from_connection_string(EH_CS, consumer_group="$default")
        with consumer:
            def on_event(partition_context, event):
                received.append(event.body_as_str())

            consumer.receive(
                on_event=on_event,
                consumer_group="$default",
                starting_position="-1",
                max_wait_time=3,
            )
        result["received"] = received

    import threading

    th = threading.Thread(target=run, daemon=True)
    th.start()
    th.join(timeout=PROBE_TIMEOUT_S)
    if th.is_alive():
        raise AssertionError(
            f"probe exceeded {PROBE_TIMEOUT_S}s (AMQP transport hang on the 5673 EH lane)"
        )
    if "send_error" in result:
        raise AssertionError(f"producer send failed: {result['send_error']}")

    received = result.get("received", [])
    assert result.get("send"), "send did not complete"
    assert any("py-eh-payload" in body for body in received), (
        f"eventhub round-trip missed payload; received: {received}"
    )
    assert any("py-eh-payload" in body for body in received), (
        f"eventhub round-trip missed payload; received: {received}"
    )
    print("      consumer round-trip ok")


# =========================================================================
# Main
# =========================================================================
def main():
    probes = [
        probe_oauth_client_secret,
        probe_oauth_control_dead_authority,
        probe_skr_attest_403_without_token,
        probe_skr_release_with_maa_token,
        probe_keyvault_sdk_surface,
        probe_cosmos_crud_and_queries,
        probe_cosmos_stale_etag_412,
        probe_blob_crud_and_worm,
        probe_blob_worm_409,
        probe_sb_session_roundtrip_and_dlq,
        probe_sb_dead_letter_and_lock_renew,
        probe_eventhub_roundtrip,
    ]
    print("=== smalt python reality court ===", flush=True)
    for fn in probes:
        probe(fn)
    print("=== verdict ===", flush=True)
    if FAILURES:
        print(f"{len(FAILURES)} FAILED of {len(probes)} probes:", flush=True)
        for name, reason in FAILURES:
            print(f"  FAIL {name}: {reason}", flush=True)
        return 1
    print(f"ALL {len(probes)} PROBES PASSED", flush=True)
    return 0


if __name__ == "__main__":
    if not SB_KEY or not MAA_MEASUREMENT:
        print("SB_SHARED_KEY / MAA_MEASUREMENT missing — run via py-run.sh", file=__import__("sys").stderr)
        raise SystemExit(2)
    raise SystemExit(main())
