"""wf9 (lane K-SQ): real-boto3 SQS court.

Real boto3 against the smalt SQS query-protocol surface (SigV4 real-signed by
botocore on every request — wire falsifier). Gates:
  G1 create/list/get-attrs   G2 send/receive MD5OfBody parity
  G3 receipt-handle law (never a dashed-UUID SB token; cross-queue refusal)
  G4 ChangeMessageVisibility vt=0 release + ApproximateReceiveCount bump
  G5 long-poll deadline + mid-poll wake
  G6 DelaySeconds invisibility + bounded-poll delivery
  G7 GetQueueAttributes counts
  G8 attributes-MD5 vs inline-Python canonical encoder (sharp falsifier)
  G9 batch partial failure (SendMessageBatch BatchResultErrorEntry)

Boot: SMALT_SQS_PORT points at a judge-booted SQS surface (the Bandit-mounted
plug or the coordinator-mounted egress router). Default 39713 (wf-lane port).
"""

import hashlib
import os
import re
import struct
import time
import uuid

import boto3
import pytest
from botocore.config import Config

PORT = os.environ.get("SMALT_SQS_PORT", "39713")
ENDPOINT = "http://127.0.0.1:%s" % PORT


def make_client():
    return boto3.client(
        "sqs",
        endpoint_url=ENDPOINT,
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test-secret",
        config=Config(retries={"total_max_attempts": 1}, read_timeout=35),
    )


client = make_client()


def canon_attributes_md5(attrs):
    """Inline-Python AWS canonical message-attribute MD5 (String type)."""
    packed = b""
    for name in sorted(attrs.keys()):
        nb = name.encode("utf-8")
        vb = attrs[name].encode("utf-8")
        packed += struct.pack(">I", len(nb)) + nb + struct.pack(">I", len(vb)) + vb
    return hashlib.md5(packed).hexdigest()


def wait_until(fn, timeout=15.0, interval=0.25):
    """Bounded poll on a real observable (no-sleep law)."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    return last


@pytest.fixture(scope="module")
def q():
    name = "wf9-court-%s" % uuid.uuid4().hex[:8]
    url = client.create_queue(QueueName=name)["QueueUrl"]
    yield url
    try:
        client.delete_queue(QueueUrl=url)
    except Exception:
        pass


def test_g1_create_list_get_attrs(q):
    r = client.get_queue_attributes(QueueUrl=q, AttributeNames=["All"])
    attrs = r["Attributes"]
    assert attrs["QueueArn"].endswith(q.rsplit("/", 1)[-1])
    assert attrs["ApproximateNumberOfMessages"] == "0"
    assert "VisibilityTimeout" in attrs

    lst = client.list_queues(QueueNamePrefix="wf9-court")
    assert any(u.endswith(q.rsplit("/", 1)[-1]) for u in lst.get("QueueUrls", []))


def test_g2_send_receive_md5_parity(q):
    body = "wf9 parity body unicode-ok"
    client.send_message(QueueUrl=q, MessageBody=body)
    r = client.receive_message(QueueUrl=q, AttributeNames=["All"], WaitTimeSeconds=1)
    msgs = r.get("Messages", [])
    assert msgs, "no message received"
    m = msgs[0]
    assert m["Body"] == body
    assert m["MD5OfBody"] == hashlib.md5(body.encode()).hexdigest()
    assert int(m["Attributes"]["ApproximateReceiveCount"]) >= 1
    assert client.delete_message(QueueUrl=q, ReceiptHandle=m["ReceiptHandle"])


def test_g3_receipt_handle_law(q):
    client.send_message(QueueUrl=q, MessageBody="handle-law")
    m = client.receive_message(QueueUrl=q)["Messages"][0]
    h = m["ReceiptHandle"]
    assert h.startswith("sqs1"), h
    # NEVER a dashed-UUID Service Bus lock token on the SQS wire
    assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", h) is None

    # cross-queue refusal
    other = client.create_queue(QueueName="wf9-court-other")["QueueUrl"]
    with pytest.raises(client.exceptions.QueueDoesNotExistException) or True:
        try:
            client.delete_message(QueueUrl=other, ReceiptHandle=h)
        except client.exceptions.ClientError as e:
            code = e.response["Error"]["Code"]
            if code != "ReceiptHandleIsInvalid":
                raise AssertionError("expected ReceiptHandleIsInvalid, got %s" % code)
        else:
            raise AssertionError("cross-queue delete must fail")

    client.delete_message(QueueUrl=q, ReceiptHandle=h)


def test_g4_cmv_release_and_receive_count(q):
    client.send_message(QueueUrl=q, MessageBody="cmv-release")
    m = client.receive_message(QueueUrl=q)["Messages"][0]
    assert int(m["Attributes"]["ApproximateReceiveCount"]) == 1
    client.change_message_visibility(QueueUrl=q, ReceiptHandle=m["ReceiptHandle"], VisibilityTimeout=0)
    m2 = wait_until(lambda: client.receive_message(QueueUrl=q, AttributeNames=["All"]).get("Messages") or None, timeout=6)
    assert m2, "vt=0 release did not return the message"
    assert int(m2[0]["Attributes"]["ApproximateReceiveCount"]) == 2
    client.delete_message(QueueUrl=q, ReceiptHandle=m2[0]["ReceiptHandle"])


def test_g5_long_poll(q):
    t0 = time.monotonic()
    r = client.receive_message(QueueUrl=q, WaitTimeSeconds=2, MaxNumberOfMessages=1)
    dt = time.monotonic() - t0
    assert dt >= 1.7, "empty long-poll returned too early: %.2fs" % dt
    assert not r.get("Messages")

    import threading

    def late_send():
        time.sleep(0.5)
        client.send_message(QueueUrl=q, MessageBody="midpoll-wake")

    th = threading.Thread(target=late_send)
    th.start()
    t1 = time.monotonic()
    r = client.receive_message(QueueUrl=q, WaitTimeSeconds=5)
    dt = time.monotonic() - t1
    th.join()
    assert r["Messages"][0]["Body"] == "midpoll-wake"
    assert dt < 3.0, "mid-poll wake took %.2fs (flush_waiters should be instant)" % dt
    client.delete_message(QueueUrl=q, ReceiptHandle=r["Messages"][0]["ReceiptHandle"])


def test_g6_delay_seconds(q):
    client.send_message(QueueUrl=q, MessageBody="delayed", DelaySeconds=1)
    r = client.receive_message(QueueUrl=q, MaxNumberOfMessages=1)
    assert not r.get("Messages"), "delayed message visible immediately"
    got = wait_until(
        lambda: client.receive_message(QueueUrl=q, WaitTimeSeconds=1).get("Messages") or None,
        timeout=8,
    )
    assert got and got[0]["Body"] == "delayed"
    client.delete_message(QueueUrl=q, ReceiptHandle=got[0]["ReceiptHandle"])


def test_g7_get_attrs_counts(q):
    for i in range(3):
        client.send_message(QueueUrl=q, MessageBody="count-%d" % i)
    a = client.get_queue_attributes(QueueUrl=q, AttributeNames=["All"])["Attributes"]
    assert a["ApproximateNumberOfMessages"] == "3"
    m = client.receive_message(QueueUrl=q)["Messages"][0]
    a = client.get_queue_attributes(QueueUrl=q, AttributeNames=["All"])["Attributes"]
    assert a["ApproximateNumberOfMessages"] == "2"
    assert a["ApproximateNumberOfMessagesNotVisible"] == "1"
    client.change_message_visibility(QueueUrl=q, ReceiptHandle=m["ReceiptHandle"], VisibilityTimeout=0)
    m2 = wait_until(lambda: client.receive_message(QueueUrl=q).get("Messages") or None, timeout=6)
    client.delete_message(QueueUrl=q, ReceiptHandle=m2[0]["ReceiptHandle"])


def test_g8_attributes_md5_canonical(q):
    attrs = {"alpha": "one", "beta": "two", "gamma-space": "three three"}
    r = client.send_message(QueueUrl=q, MessageBody="with-attrs", MessageAttributes=attrs)
    assert r["MD5OfMessageBody"] == hashlib.md5(b"with-attrs").hexdigest()
    assert r["MD5OfMessageAttributes"] == canon_attributes_md5(attrs), (
        "attributes MD5 mismatch vs inline canonical encoder"
    )
    # boto3 ALSO verifies MD5OfMessageAttributes client-side on receive when
    # MessageAttributeNames requested; a divergence raises there.
    r = client.receive_message(
        QueueUrl=q, MessageAttributeNames=["All"], WaitTimeSeconds=1
    )
    m = r["Messages"][0]
    assert m["MessageAttributes"] == attrs
    client.delete_message(QueueUrl=q, ReceiptHandle=m["ReceiptHandle"])


def test_g9_batch_partial_failure(q):
    r = client.send_message_batch(
        QueueUrl=q,
        Entries=[
            {"Id": "ok1", "MessageBody": "batch-ok"},
            {"Id": "bad1", "MessageBody": ""},
        ],
    )
    ok_ids = [e["Id"] for e in r.get("Successful", [])]
    bad = r.get("Failed", [])
    assert "ok1" in ok_ids
    assert any(e["Id"] == "bad1" for e in bad)
    m = client.receive_message(QueueUrl=q, WaitTimeSeconds=1).get("Messages", [])
    assert any(x["Body"] == "batch-ok" for x in m)


def test_g10_version_gate():
    import urllib.request

    body = "Action=SendMessage&Version=2009-02-01&QueueUrl=http://x/000000000000/nope&MessageBody=hi"
    req = urllib.request.Request(
        ENDPOINT + "/",
        data=body.encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        status = resp.status
        payload = resp.read().decode()
    except urllib.error.HTTPError as e:  # noqa: F821
        status = e.code
        payload = e.read().decode()
    assert status == 400
    assert "InvalidAction" in payload


import urllib.error  # noqa: E402
