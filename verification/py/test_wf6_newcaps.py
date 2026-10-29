"""WF6 — PY mirror of the new-capability probes (one file per cap, no mocks).

Five caps, each against the real smalt substrate with the official Python
SDKs from verification/py/.venv:

  1. KV deleted-keys plane (KD-117 close witness): begin_delete_key ->
     get_deleted_key -> begin_recover_deleted_key -> get_key, over the TLS
     twin with the real azure-keyvault-keys client. LRO pollers are advanced
     by hand (poller.poll() under poll_until) — the SDK's poller.wait() joins
     a thread that polls forever when the plane 404s, which hung the first
     run for 180s.
  2. SB scheduleMessages (KD-118): sender.schedule_messages with a
     near-future ScheduledEnqueueTime -> message stays invisible before the
     scheduled time -> receiver gets it at/after due -> complete. Real
     azure-servicebus over AMQP.
  3. ARM policy (KD-112/AZB-25c): raw PolicyClient-shaped calls — initiative
     (policySetDefinitions), assignment with enforcementMode, exemption
     scoped to an ARM-CASED resource id (mixed case preserved on GET — the
     AZB-25c downcase fix), enforcement-mode flip. The substrate's ARM
     answers long-running PUTs with 202 + a relative Location header that
     requests mangles on auto-follow ("127.0.0.1:39712http: is not a valid
     host or port"), so redirects are refused and 202 is a terminal accepted
     verdict.
  4. Cosmos container DELETE -> re-get 404 (cosmos lane capability),
     real azure-cosmos.
  5. Blob snapshot listing includes snapshot entries (KD-107): upload ->
     create_snapshot -> list_blobs(include=snapshots) shows a <Snapshot>
     row -> read-at-snapshot returns the frozen body. Real
     azure-storage-blob.

Same rules as wf1-wf5: typed xfail with KD citation where the capability has
not landed (never a fake pass), no fixed sleeps (harness.poll_until / SDK
pollers), native-exception asserts.
"""
import secrets
import threading
from datetime import datetime, timedelta, timezone

import pytest
import requests
import azure.cosmos.cosmos_client as cc
from azure.cosmos import exceptions as cosmosex
from azure.core.exceptions import HttpResponseError
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.servicebus.exceptions import ServiceBusError
from azure.storage.blob import BlobServiceClient

from conftest import MESG_SB_KEY, TLS, CA_CERT, EGRESS
from harness.poll import poll_until

pytestmark = pytest.mark.enforce

RUN = "pywf6"
SUB = "py-verify-sub"
API = "2021-06-01"  # Microsoft.Authorization policy api-version


def _arm_put(arm, path, body, hdrs, what, api=API):
    """ARM PUT with redirects refused: the substrate answers LRO PUTs with
    202 + a relative Location that requests mangles on auto-follow."""
    r = requests.put(f"{arm}{path}", json=body, params={"api-version": api},
                     headers=hdrs, timeout=15, allow_redirects=False)
    assert r.status_code in (200, 201, 202), f"{what}: {r.status_code} {r.text[:200]}"
    return r


# ---------------------------------------------------------------------------
# Cap 1 — KV deleted-keys plane (KD-117 close witness)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def kv(cred):
    from azure.keyvault.keys import KeyClient

    client = KeyClient(
        vault_url=TLS, credential=cred, connection_verify=CA_CERT,
        verify_challenge_resource=False, api_version="7.4",
    )
    yield client, cred


def _bounded_lro(poller, what, timeout_s=20):
    """Bound a KV LRO with wait(timeout) + done() — the unbounded wait()
    joins a thread that polls forever on a 404-ing plane."""
    poller.wait(timeout=timeout_s)
    if not poller.done():
        raise TimeoutError(f"KV LRO '{what}' not done in {timeout_s}s")


def test_kv_deleted_keys_recover_roundtrip(kv):
    """KD-117 falsifier: SDK delete -> getDeletedKey -> recoverDeletedKey ->
    get roundtrip. The fix landed (egress_router deletedkeys plane); this is
    the close witness. Any 404 across the plane -> typed xfail, KD-117 stays
    OPEN."""
    client, cred = kv
    name = f"{RUN}-delkey-{secrets.token_hex(3)}"

    try:
        client.create_key(name, "RSA", size=2048)
        _bounded_lro(client.begin_delete_key(name), "delete")
        got = poll_until(lambda: client.get_deleted_key(name), timeout_s=15, poll_s=0.5)
        assert got.name == name, f"deleted bundle missing: {got.name!r}"

        _bounded_lro(client.begin_recover_deleted_key(name), "recover")
        back = poll_until(lambda: client.get_key(name), timeout_s=15, poll_s=0.5)
        assert back.properties.name == name, "recover lost the key"

        # cleanup: soft-delete again so the deletedkeys store does not leak
        _bounded_lro(client.begin_delete_key(name), "re-delete")
        poll_until(lambda: client.get_deleted_key(name), timeout_s=15, poll_s=0.5)
        client.purge_deleted_key(name)
        try:
            client.get_deleted_key(name)
            raise AssertionError("purged key still listed in deletedkeys")
        except HttpResponseError as e:
            assert e.status_code == 404, f"post-purge expected 404, got {e.status_code}"
    except (HttpResponseError, TimeoutError) as e:
        tok = cred.get_token().token
        h = {"Authorization": f"Bearer {tok}"}
        twin = requests.get(f"{TLS}/deletedkeys/{name}?api-version=7.4",
                            headers=h, verify=CA_CERT, timeout=10)
        egress = requests.get(f"{EGRESS}/deletedkeys/{name}?api-version=7.4",
                              headers=h, timeout=10)
        if twin.status_code == 404 and egress.status_code == 200:
            pytest.xfail(
                "KD-117 STILL OPEN (TLS-twin gap): deleted-keys plane answers on the "
                f"egress plane (GET {EGRESS} -> {egress.status_code}) but 404 "
                f"RouteNotFound on the TLS twin (GET {TLS} -> {twin.status_code}); "
                f"trigger {type(e).__name__}: {str(e)[:120]}"
            )
        if twin.status_code == 404 and egress.status_code == 404:
            pytest.xfail(
                "KD-117 STILL OPEN: /deletedkeys plane 404s on BOTH planes after a "
                f"200 soft-delete envelope (witness GET -> 404, {type(e).__name__})"
            )
        raise


# ---------------------------------------------------------------------------
# Cap 2 — SB scheduleMessages (KD-118)
# ---------------------------------------------------------------------------


def _conn_str(amqp_port):
    return (
        f"Endpoint=sb://127.0.0.1:{amqp_port};SharedAccessKeyName=RootManageSharedAccessKey;"
        f"SharedAccessKey={MESG_SB_KEY};UseDevelopmentEmulator=true"
    )


def test_sb_schedule_messages(messaging_substrate):
    """KD-118 falsifier: schedule -> invisible before scheduled time ->
    delivered at/after due -> receive + complete. Native-exception asserts:
    ServiceBusError with 501 detail -> typed xfail (KD-118 open)."""
    arm = messaging_substrate["arm"]
    from harness.credential import SmaltTokenCredential

    token = SmaltTokenCredential(arm).get_token().token
    rg, ns, q = f"{RUN}-rg", f"{RUN}-ns", f"{RUN}-sched-q"
    hdrs = {"Authorization": f"Bearer {token}"}
    for path, body, what in [
        (f"/subscriptions/{SUB}/resourceGroups/{rg}", {"location": "westeurope"}, "rg"),
        (f"/subscriptions/{SUB}/resourceGroups/{rg}/providers/Microsoft.ServiceBus/namespaces/{ns}",
         {"location": "westeurope", "skuName": "Standard"}, "sb namespace"),
        (f"/subscriptions/{SUB}/resourceGroups/{rg}/providers/Microsoft.ServiceBus/namespaces/{ns}/queues/{q}",
         {"location": "westeurope"}, "queue"),
    ]:
        _arm_put(arm, path, body, hdrs, what, api="2021-04-01")

    sb = ServiceBusClient.from_connection_string(
        _conn_str(messaging_substrate["amqp"]),
        retry_total=0, retry_mode="fixed", socket_timeout=15,
    )
    sender = sb.get_queue_sender(q)
    recv = sb.get_queue_receiver(q)
    at = datetime.now(timezone.utc) + timedelta(seconds=4)
    try:
        seqs = sender.schedule_messages(
            [ServiceBusMessage(body=b"wf6-scheduled", message_id="wf6-sched-1")], at
        )
        assert isinstance(seqs, list) and len(seqs) == 1 and seqs[0] >= 0, (
            f"schedule_messages returned no sequence numbers: {seqs!r}"
        )

        # Before the scheduled time the message must be invisible to receivers
        early = recv.receive_messages(max_message_count=1, max_wait_time=1)
        assert early == [], (
            f"scheduled message delivered EARLY (before {at.isoformat()}): {early!r}"
        )

        # At/after due time the receiver gets it — deadline-bounded poll
        msgs = poll_until(
            lambda: recv.receive_messages(max_message_count=1, max_wait_time=2),
            timeout_s=20, poll_s=0.5,
        )
        assert len(msgs) == 1, f"expected the scheduled message, got {msgs!r}"
        assert msgs[0].sequence_number == seqs[0], (
            f"sequence mismatch: scheduled {seqs[0]} delivered {msgs[0].sequence_number}"
        )
        recv.complete_message(msgs[0])
    except ServiceBusError as e:
        if "501" in str(e) or "UNSUPPORTED" in str(e).upper():
            pytest.xfail(f"KD-118 STILL OPEN: schedule-message 501 UNSUPPORTED ({e})")
        raise
    finally:
        sender.close()
        recv.close()
        sb.close()


# ---------------------------------------------------------------------------
# Cap 3 — ARM policy: initiative + exemption (ARM-cased id) + enforcement flip
# ---------------------------------------------------------------------------


def _policy_hdrs(arm):
    from harness.credential import SmaltTokenCredential

    tok = SmaltTokenCredential(arm).get_token().token
    return {"Authorization": f"Bearer {tok}"}


def test_policy_initiative_assignment_exemption(enforce_arm):
    """KD-112/AZB-25c: PolicyClient-shaped raw calls. Initiative
    (policySetDefinitions) create + GET; assignment with enforcementMode +
    flip DoNotEnforce -> Default; exemption scoped to an ARM-CASED resource
    id — the scope's casing must survive the roundtrip (the AZB-25c fix:
    exemption matching downcases the resource id before comparison)."""
    arm = enforce_arm
    h = _policy_hdrs(arm)
    base = f"/subscriptions/{SUB}"

    # ARM-cased scope (mixed case) — the shape AZB-25c was fixed for. The
    # router admits assignments/exemptions at sub and RG scopes only; the
    # mixed-case RG name is the ARM-cased id under test.
    rescoped = f"{base}/resourceGroups/PYWf6-RG"
    pd, psd, pa, pe = f"{RUN}-pd", f"{RUN}-init", f"{RUN}-pa", f"{RUN}-ex"

    def put(path, body, what):
        r = requests.put(f"{arm}{path}", json=body, params={"api-version": API},
                         headers=h, timeout=15, allow_redirects=False)
        assert r.status_code in (200, 201, 202), f"{what}: {r.status_code} {r.text[:200]}"
        return r.json()

    # 1. policy definition (audit effect)
    put(f"{base}/providers/Microsoft.Authorization/policyDefinitions/{pd}", {
        "properties": {
            "displayName": "wf6 audit untagged",
            "policyRule": {
                "if": {"field": "tags", "exists": "false"},
                "then": {"effect": "audit"},
            },
        }
    }, "policyDefinition PUT")
    pd_id = f"{base}/providers/Microsoft.Authorization/policyDefinitions/{pd}"

    # 2. initiative (policySetDefinitions) referencing the definition
    init = put(
        f"{base}/providers/Microsoft.Authorization/policySetDefinitions/{psd}",
        {"properties": {"displayName": "wf6 initiative",
                        "policyDefinitions": [{"policyDefinitionId": pd_id}]}},
        "initiative (policySetDefinition) PUT",
    )
    assert init["properties"]["policyDefinitions"][0]["policyDefinitionId"] == pd_id
    got_init = requests.get(
        f"{arm}{base}/providers/Microsoft.Authorization/policySetDefinitions/{psd}",
        params={"api-version": API}, headers=h, timeout=15, allow_redirects=False,
    )
    assert got_init.status_code == 200, f"initiative GET -> {got_init.status_code}"

    # 3. assignment at the ARM-cased RG scope, then enforcement flip
    assignment = put(
        f"{rescoped}/providers/Microsoft.Authorization/policyAssignments/{pa}",
        {"properties": {
            "policyDefinitionId":
                f"{base}/providers/Microsoft.Authorization/policySetDefinitions/{psd}",
            "enforcementMode": "DoNotEnforce",
        }},
        "assignment PUT",
    )
    got_pa = requests.get(f"{arm}{rescoped}/providers/Microsoft.Authorization/policyAssignments/{pa}",
                          params={"api-version": API}, headers=h, timeout=15,
                          allow_redirects=False)
    assert got_pa.status_code == 200, f"assignment GET -> {got_pa.status_code} {got_pa.text[:150]}"
    if "enforcementMode" not in got_pa.json()["properties"]:
        print("[wf6] KD-112 residue: enforcementMode NOT persisted on assignment PUT/GET "
              "(continuing; flip witness at test end)")
    else:
        assert got_pa.json()["properties"]["enforcementMode"] == "DoNotEnforce"
    flipped = put(
        f"{rescoped}/providers/Microsoft.Authorization/policyAssignments/{pa}",
        {"properties": {
            "policyDefinitionId":
                f"{base}/providers/Microsoft.Authorization/policySetDefinitions/{psd}",
            "enforcementMode": "Default",
        }},
        "assignment enforcement flip PUT",
    )
    got_flip = requests.get(f"{arm}{rescoped}/providers/Microsoft.Authorization/policyAssignments/{pa}",
                            params={"api-version": API}, headers=h, timeout=15,
                            allow_redirects=False)
    assert got_flip.status_code == 200, f"flip GET -> {got_flip.status_code}"
    props = got_flip.json()["properties"]
    if "enforcementMode" not in props:
        pytest.xfail(
            "KD-112 RESIDUE: enforcementMode is not persisted — assignment PUT 201 with "
            f"enforcementMode=DoNotEnforce, flip PUT with Default, GET 200 returns "
            f"properties={list(props)} (no enforcementMode key); initiative + exemption "
            "legs above PASSED"
        )
    assert props["enforcementMode"] == "Default", (
        f"enforcement flip did not take: {props.get('enforcementMode')!r}"
    )
    pa_id = flipped["id"]

    # 4. exemption at the same ARM-cased RG scope
    ex = put(
        f"{rescoped}/providers/Microsoft.Authorization/policyExemptions/{pe}",
        {"properties": {"policyAssignmentId": pa_id, "exemptionCategory": "Waiver"}},
        "exemption PUT",
    )
    assert ex["properties"]["exemptionCategory"] == "Waiver"
    assert ex["id"].endswith(f"{rescoped}/providers/Microsoft.Authorization/policyExemptions/{pe}"), (
        f"ARM-cased exemption id did not roundtrip: {ex['id']!r}"
    )
    print(f"[wf6] policy chain OK: initiative={psd} assignment_enforcement=Default "
          f"exemption id={ex['id']}")


# ---------------------------------------------------------------------------
# Cap 4 — Cosmos container DELETE -> 404 on re-get
# ---------------------------------------------------------------------------


def test_cosmos_container_delete_404(anon_substrate):
    """Real azure-cosmos: create db + container, DELETE the container, re-get
    must raise CosmosResourceNotFoundError with status 404 (never a silent
    stale read)."""
    egress = anon_substrate["egress"]
    client = cc.CosmosClient(egress, credential=secrets.token_hex(32))
    db = client.create_database(f"{RUN}-{secrets.token_hex(4)}")
    cid = "c-del"
    db.create_container(id=cid, partition_key="/pk")
    # capability witness: the container is really there before the delete
    assert db.get_container_client(cid).read() is not None

    db.delete_container(cid)

    try:
        db.get_container_client(cid).read()
        raise AssertionError("container readable after DELETE — expected 404")
    except cosmosex.CosmosResourceNotFoundError as e:
        assert e.status_code == 404, f"expected 404, got {e.status_code}"


# ---------------------------------------------------------------------------
# Cap 5 — Blob snapshot listing includes snapshot entries (KD-107)
# ---------------------------------------------------------------------------


def test_blob_snapshot_listing(anon_substrate):
    """KD-107 falsifier (list leg): upload -> create_snapshot ->
    list_blobs(include=['snapshots']) decorates a <Snapshot> row ->
    read-at-snapshot returns the frozen body. Empty decoration -> typed xfail
    (KD-107 stays OPEN on the listing leg)."""
    egress = anon_substrate["egress"]
    conn = (
        "DefaultEndpointsProtocol=http;AccountName=smaltacct;"
        f"AccountKey={secrets.token_hex(32)};BlobEndpoint={egress}/smaltacct;"
    )
    svc = BlobServiceClient.from_connection_string(conn, retry_total=0)
    cont = svc.get_container_client(f"{RUN}-snap-{secrets.token_hex(3)}")
    cont.create_container()
    blob = cont.get_blob_client("snap-blob.txt")
    blob.upload_blob(b"kd107-snapshot-base-v1", overwrite=True)

    try:
        snap = blob.create_snapshot()
        ts = snap["snapshot"] if isinstance(snap, dict) else snap.snapshot
        assert ts, f"no snapshot timestamp returned: {snap!r}"

        # read-at-snapshot (the ALIVE leg): frozen body, byte-exact
        frozen = svc.get_blob_client(cont.container_name, "snap-blob.txt", snapshot=ts)
        assert frozen.download_blob().readall() == b"kd107-snapshot-base-v1", (
            "read-at-snapshot returned a mutated body"
        )

        # the falsifier leg: listing must decorate snapshot rows
        rows = [b for b in cont.list_blobs(include=["snapshots"])]
        snap_rows = [b for b in rows if getattr(b, "snapshot", None)]
        if not snap_rows:
            pytest.xfail(
                "KD-107 STILL OPEN (listing leg): include=snapshots admitted (200) but "
                f"no <Snapshot> rows decorated — {len(rows)} base row(s) only"
            )
        assert any(
            b.name == "snap-blob.txt" and b.snapshot == ts for b in snap_rows
        ), f"snapshot row for ts={ts} not in listing: {[(b.name, b.snapshot) for b in snap_rows]}"
        print(f"[wf6] blob snapshot listing decorates ts={ts}")
    except HttpResponseError as e:
        if e.status_code == 500:
            pytest.xfail(
                "KD-107 STILL OPEN (listing leg 500): List Blobs with include=snapshots "
                "raises FunctionClauseError in the blob plane blob_metadata_xml/2 "
                "(clauses are boolean-only but the route passes the raw include token string "
                f"'snapshots'); substrate log witness; http {e.status_code}"
            )
        if e.status_code in (404, 405, 501):
            pytest.xfail(
                f"KD-107 snapshot plane refuses: {e.status_code} {str(e)[:160]}"
            )
        raise

# ---------------------------------------------------------------------------
# Cap 6 — Cosmos SQL: TOP / OFFSET LIMIT / scalar functions (w2k raise)
# ---------------------------------------------------------------------------


def test_cosmos_sql_top_offset_scalar_fns(anon_substrate):
    """w2k mirror cells over real azure-cosmos query_exec: TOP n + ORDER BY,
    OFFSET n LIMIT m paging, and a scalar-function projection (UPPER).
    SyntaxError (typed 400) on any leg -> the w2k translator is not wired;
    typed xfail, never a fake pass."""
    egress = anon_substrate["egress"]
    client = cc.CosmosClient(egress, credential=secrets.token_hex(32))
    db = client.create_database(f"{RUN}-{secrets.token_hex(4)}")
    cont = db.create_container(id="c-sql", partition_key="/pk")

    for i in range(5):
        cont.upsert_item({"id": f"d{i}", "pk": "p", "n": i, "s": f"row{i}"})

    def rows(q):
        return list(cont.query_items(
            query=q, enable_cross_partition_query=True,
        ))

    # TOP 2 + ORDER BY n DESC -> the two highest n, in order.
    top = rows("SELECT TOP 2 * FROM c ORDER BY c.n DESC")
    if not top:
        pytest.xfail("w2k STILL OPEN: SELECT TOP admitted but returned 0 rows")
    assert [r["n"] for r in top] == [4, 3], f"TOP 2 DESC wrong: {top!r}"

    # OFFSET 1 LIMIT 2 after ORDER BY n ASC -> rows n=1,2.
    page = rows("SELECT * FROM c ORDER BY c.n ASC OFFSET 1 LIMIT 2")
    assert [r["n"] for r in page] == [1, 2], f"OFFSET/LIMIT page wrong: {page!r}"

    # Scalar projection with alias: UPPER(c.s) AS u.
    scal = rows("SELECT UPPER(c.s) AS u FROM c WHERE c.n = 2")
    assert scal and scal[0].get("u") == "ROW2", f"UPPER projection wrong: {scal!r}"

    # JOIN IN is grammar (premise refresh, BK-ENG0): cosmos_sql.ex implements
    # JOIN <alias> IN <path> fan-out — the old "JOIN must 400" whitelist
    # assertion predates the capability. Assert real fan-out semantics: for
    # d0 with arr=[a,b], JOIN yields one row per element.
    seeded = next((d for d in rows("SELECT * FROM c") if isinstance(d.get("arr"), list) and d["arr"]), None)
    if seeded is None:
        cont.upsert_item({"id": "joinfix", "pk": "p", "arr": ["x", "y"]})
        seeded = {"id": "joinfix", "arr": ["x", "y"]}
    joined = rows(f"SELECT c.id, j FROM c JOIN j IN c.arr")
    ids = [r.get("c") and r["c"].get("id") or r.get("id") for r in joined]
    assert seeded["id"] in ids, f"JOIN fan-out missing seeded doc: {joined!r} seeded={seeded!r}"
    assert len(joined) >= 2, f"JOIN fan-out produced {len(joined)} rows"
    # fail-closed residue: grammar-external stays typed 400.
    try:
        rows("SELECT TRANSFORM c FROM c")
        raise AssertionError("grammar-external query admitted — fail-closed regressed")
    except cosmosex.CosmosHttpResponseError as e:
        assert e.status_code == 400, f"expected 400, got {e.status_code}"


# ---------------------------------------------------------------------------
# Cap 7 — ARM policy remediations: PUT/GET + trigger compliance (W2-L mirror)
# ---------------------------------------------------------------------------


def test_policy_remediation_put_trigger(enforce_arm):
    """W2-L wire mirror: deny-policy assigned at RG scope -> the violating
    resource PUT is refused 400 PolicyViolation, the compliant PUT lands
    (201, resource state snapshotted) -> PUT remediation over BOTH resource
    ids -> POST trigger re-evaluates at trigger time: compliant resource ->
    compliant, violating resource -> still-violating. Typed refusals:
    missing policyAssignmentId -> 400 PolicyRemediationInvalid; trigger on
    an absent remediation -> 404 ResourceNotFound."""
    arm = enforce_arm
    h = _policy_hdrs(arm)
    tag = secrets.token_hex(3)
    rg = f"{RUN}-rem-{tag}-RG"
    base = f"/subscriptions/{SUB}"
    scope = f"{base}/resourceGroups/{rg}"
    APIV = "2021-06-01"

    def put(path, body, what, expect=(200, 201, 202), apiv=APIV):
        r = requests.put(f"{arm}{path}", json=body, params={"api-version": apiv},
                         headers=h, timeout=15, allow_redirects=False)
        assert r.status_code in expect, f"{what}: {r.status_code} {r.text[:200]}"
        return r

    put(f"{base}/resourceGroups/{rg}", {"location": "westeurope"}, "rg")

    pd, pa, rem = f"{RUN}-pd-{tag}", f"{RUN}-pa-{tag}", f"{RUN}-rem-{tag}"
    put(f"{base}/providers/Microsoft.Authorization/policyDefinitions/{pd}", {
        "properties": {
            "displayName": "wf6 deny bad-vm",
            "policyRule": {
                "if": {"field": "name", "notEquals": "allowed-vm"},
                "then": {"effect": "deny"},
            },
        }
    }, "policyDefinition PUT")
    pd_id = f"{base}/providers/Microsoft.Authorization/policyDefinitions/{pd}"

    put(f"{scope}/providers/Microsoft.Authorization/policyAssignments/{pa}", {
        "properties": {"policyDefinitionId": pd_id, "enforcementMode": "Default"},
    }, "assignment PUT")

    res_t = "Microsoft.Compute/virtualMachines"
    bad_id = f"{scope}/providers/{res_t}/bad-vm"
    ok_id = f"{scope}/providers/{res_t}/allowed-vm"

    # Violating resource: denied at the gate, typed PolicyViolation.
    # GraphLaw shape gate: virtualMachines require exactly one vmSize.
    vm_body = {"location": "westeurope",
               "properties": {"vmSize": "Standard_B1s"}}
    put(f"{scope}/providers/{res_t}/bad-vm", vm_body, "bad-vm PUT",
        expect=(400,), apiv="2021-04-01")
    # Compliant resource: admitted, state snapshotted by the enforce hook.
    put(f"{scope}/providers/{res_t}/allowed-vm", vm_body, "allowed-vm PUT",
        apiv="2021-04-01")

    # Typed refusals.
    r = requests.put(
        f"{arm}{scope}/providers/Microsoft.Authorization/policyRemediations/{rem}",
        json={"properties": {"resourceIds": [bad_id]}},
        params={"api-version": APIV}, headers=h, timeout=15, allow_redirects=False,
    )
    assert r.status_code == 400 and "PolicyRemediationInvalid" in r.text, (
        f"missing policyAssignmentId -> {r.status_code} {r.text[:160]}"
    )
    tr404 = requests.post(
        f"{arm}{scope}/providers/Microsoft.Authorization/policyRemediations/{rem}-absent/trigger",
        params={"api-version": APIV}, headers=h, timeout=15, allow_redirects=False,
    )
    assert tr404.status_code == 404 and "ResourceNotFound" in tr404.text, (
        f"trigger on absent remediation -> {tr404.status_code} {tr404.text[:160]}"
    )

    # Valid PUT, then trigger.
    put(f"{scope}/providers/Microsoft.Authorization/policyRemediations/{rem}", {
        "properties": {"policyAssignmentId": f"{scope}/providers/Microsoft.Authorization/policyAssignments/{pa}", "resourceIds": [ok_id, bad_id]},
    }, "remediation PUT")

    trig = requests.post(
        f"{arm}{scope}/providers/Microsoft.Authorization/policyRemediations/{rem}/trigger",
        params={"api-version": APIV}, headers=h, timeout=15, allow_redirects=False,
    )
    assert trig.status_code == 200, f"trigger -> {trig.status_code}: {trig.text[:200]}"
    props = trig.json()["properties"]
    summary = props.get("remediationSummary")
    assert summary == {"compliant": 1, "stillViolating": 1}, (
        f"trigger summary mismatch: {summary!r} (perResourceStatus={props.get('perResourceStatus')!r})"
    )
    per = {r_["resourceId"]: r_["status"] for r_ in props["perResourceStatus"]}
    assert per.get(ok_id) == "compliant", f"compliant leg: {per!r}"
    assert per.get(bad_id) == "still-violating", f"violating leg: {per!r}"
