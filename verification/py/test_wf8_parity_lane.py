"""wf8-parity-lane — official Python SDKs against the v26.10.28 parity fixes.

Targets the parity-lane tickets (docs/jira/v26.10.28/tickets/):
  T-17 snapshot-delete matrix, T-18 content-type serving, the 8a6ce57 blob
  comp surfaces (lease/append/page/properties/block ids), and the queue SDK
  wire shapes (bare-shape routing, metadata 204s, update 204).

Environment: the py-verify contract (conftest) — point SMALT_PY_EGRESS at a
RUNNING anonymous substrate to skip the boot fixtures entirely (this file
uses no boot fixtures; it is a pure client of an existing substrate):

  SMALT_PY_EGRESS=http://127.0.0.1:8443 pytest test_wf8_parity_lane.py

Python SDK shared-key dev account on smalt: account "smaltacct" with any
key (anonymous mode signs but does not verify). This also exercises the
PYTHON SDK wire shapes (a second client family beyond the JS SDKs the
parity harness used).
"""
import os
import uuid

import pytest
from azure.storage.blob import (
    BlobLeaseClient,
    BlobServiceClient,
    ContentSettings,
)
from azure.storage.queue import QueueServiceClient
from azure.core.exceptions import HttpResponseError, ResourceNotFoundError

EGRESS = os.environ.get("SMALT_PY_EGRESS", "http://127.0.0.1:8443")
ACCOUNT = os.environ.get("SMALT_PARITY_ACCOUNT", "smaltacct")
KEY = os.environ.get(
    "SMALT_PARITY_KEY",
    "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==",
)

RUN = uuid.uuid4().hex[:8]


@pytest.fixture(scope="module")
def blob_svc():
    return BlobServiceClient(f"{EGRESS}/{ACCOUNT}", credential=KEY)


@pytest.fixture(scope="module")
def queue_svc():
    return QueueServiceClient(f"{EGRESS}/{ACCOUNT}", credential=KEY)


def test_blob_snapshot_delete_matrix(blob_svc):
    """T-17: plain delete 409 SnapshotsPresent; include deletes both."""
    cont = blob_svc.get_container_client(f"pywf8sd{RUN}")
    cont.create_container()
    blob = cont.get_blob_client("snap.txt")
    blob.upload_blob(b"v1")
    blob.create_snapshot()

    with pytest.raises(HttpResponseError) as plain:
        blob.delete_blob()
    assert plain.value.status_code == 409
    assert "SnapshotsPresent" in str(plain.value)

    blob.delete_blob(delete_snapshots="include")
    with pytest.raises(ResourceNotFoundError):
        blob.download_blob()

    cont.delete_container()


def test_blob_content_type_serving(blob_svc):
    """T-18: set_http_headers -> get_blob_properties serves the content type."""
    cont = blob_svc.get_container_client(f"pywf8ct{RUN}")
    cont.create_container()
    blob = cont.get_blob_client("ct.txt")
    blob.upload_blob(b"ct-body")

    blob.set_http_headers(ContentSettings(content_type="text/plain"))
    props = blob.get_blob_properties()
    assert (props.content_settings.content_type or "").startswith("text/plain")

    cont.delete_container()


def test_blob_lease_append_page(blob_svc):
    """8a6ce57 batch: lease acquire/release, append, page, block staging."""
    cont = blob_svc.get_container_client(f"pywf8lap{RUN}")
    cont.create_container()

    lease_blob = cont.get_blob_client("lease.txt")
    lease_blob.upload_blob(b"lv1")
    lease = BlobLeaseClient(lease_blob)
    lease.acquire(lease_duration=15)
    assert lease.id
    lease.release()

    app = cont.get_blob_client("app.bin")
    app.upload_blob(b"a")
    app.append_block(b"b")
    assert app.download_blob().readall() == b"ab"

    page = cont.get_blob_client("page.bin")
    page.create_page_blob(512)
    page.upload_page(b"x" * 512, 0, 512)
    got = page.download_blob().readall()
    assert len(got) == 512 and got == b"x" * 512

    # NOTE: the python SDK base64-encodes block ids itself, so an
    # invalid-id probe is client-impossible here (that leg is covered by
    # the beam and JS parity tiers).
    staged = cont.get_blob_client("staged.bin")
    staged.stage_block("YjE=", b"s1")
    staged.commit_block_list(["YjE="])
    assert staged.download_blob().readall() == b"s1"

    cont.delete_container()


def test_queue_sdk_wire_shapes(queue_svc):
    """Queue plane through the PYTHON SDK (second client family): lifecycle,
    metadata read-back, send/receive/update/delete, listing, delete-then-404."""
    q = queue_svc.get_queue_client(f"pywf8q{RUN}")
    q.create_queue()
    # Lifecycle observable through properties (create's own return is void).
    assert q.get_queue_properties() is not None

    q.set_queue_metadata(metadata={"parity": "pywf8"})
    assert q.get_queue_properties().metadata.get("parity") == "pywf8"

    q.send_message("pywf8-body")
    msgs = list(q.receive_messages(messages_per_page=1, visibility_timeout=60))
    assert len(msgs) == 1
    assert msgs[0].content == "pywf8-body"

    # Update rotates the pop receipt, and the 204 carries no new receipt
    # (Azurite-shaped); delete must therefore ride a FRESH receive, not the
    # pre-update object. visibility_timeout=0 makes the update immediately
    # visible again.
    q.update_message(msgs[0].id, msgs[0].pop_receipt, "pywf8-updated", visibility_timeout=0)
    again = list(q.receive_messages(messages_per_page=1, visibility_timeout=60))
    assert len(again) == 1
    assert again[0].content == "pywf8-updated"
    q.delete_message(again[0])

    names = [qe.name for qe in queue_svc.list_queues()]
    assert f"pywf8q{RUN}" in names

    q.delete_queue()
    with pytest.raises(HttpResponseError) as gone:
        q.send_message("should-fail")
    assert gone.value.status_code == 404
