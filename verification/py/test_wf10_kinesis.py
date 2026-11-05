"""wf10-kinesis — official AWS SDK (boto3) against the smalt Kinesis JSON face.

K-IN lane (v26.11.6+). The Kinesis face (Smalt.Egress.KinesisRoutes) is a
delegator in the w6r_fallthrough chain: POST / with an X-Amz-Target answered
by the Kinesis delegator ahead of the main EgressRouter (coordinator mount:
`plug Smalt.Egress.KinesisRoutes` ahead of the existing face plugs in
lib/smalt/egress_router.ex — DISCLOSED mount line, outside the lane lease).

Environment (pure client of a RUNNING substrate, wf8 pattern):

  SMALT_PY_EGRESS=http://127.0.0.1:8443 pytest verification/py/test_wf10_kinesis.py

Gates:
  1. ClientError classification: an oversized PutRecord (> 1 MiB Data) is a
     typed 400 ClientError with code InvalidArgumentException (botocore
     classifies via __type, never BotoCoreError).
  2. Order-preserving PutRecords: 5 records in one call read back in order
     with strictly increasing sequence numbers.
  3. Transmute fidelity: PartitionKey -> ShardId per the recomputed KD-76
     law (md5 first byte mod 2), Data bytes byte-exact, seq order preserved.
"""
import base64
import hashlib
import os

import boto3
import pytest
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

EGRESS = os.environ.get("SMALT_PY_EGRESS", "http://127.0.0.1:8443")
REGION = os.environ.get("SMALT_KIN_REGION", "smalt-1")

RUN = os.environ.get("SMALT_KIN_RUN", "py")
STREAM = f"wf10-{RUN}"


def _kin():
    return boto3.client(
        "kinesis",
        endpoint_url=EGRESS,
        region_name=REGION,
        aws_access_key_id="smalt-py-akid",
        aws_secret_access_key="smalt-py-secret",
        config=Config(
            retries={"total_max_attempts": 1},
            connect_timeout=5,
            read_timeout=10,
        ),
    )


def _put(port_stream, body: bytes, pk: str):
    kin = _kin()
    return kin.put_record(
        StreamName=port_stream,
        Data=body,
        PartitionKey=pk,
    )


def _read_all(kin, stream, shard, iterator=None):
    token = iterator or kin.get_shard_iterator(
        StreamName=stream, ShardId=shard, ShardIteratorType="TRIM_HORIZON"
    )["ShardIterator"]

    out = []
    while True:
        page = kin.get_records(ShardIterator=token)
        out.extend(page["Records"])
        if not page["Records"] or "NextShardIterator" not in page:
            break
        token = page["NextShardIterator"]

    return out


def _shard_for(pk: str) -> str:
    # KD-76 law recomputed in Python: md5(pk) first byte mod 2 -> shard index
    # over the pinned 2-shard registry (shardId-000000000000/001).
    idx = hashlib.md5(pk.encode()).digest()[0] % 2
    return f"shardId-{idx:012d}"


def _loud_skip():
    # Typed loud skip (rc=3 class): never a fake pass.
    import sys

    print("SKIP[rc=3]: kinesis face not mounted on substrate (coordinator one-liner pending)")
    sys.exit(3)


def _face_mounted(kin) -> bool:
    # The Kinesis delegator answers POST / + X-Amz-Target; before the
    # coordinator mount lands, the blob face answers instead. Detect and
    # loud-skip (rc=3 class) — never a fake pass.
    try:
        kin.list_streams()
        return True
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        # The blob face answers POST / with a non-Kinesis error shape.
        return code in {
            "InvalidActionException",
            "MissingAuthenticationTokenException",
            "SerializationException",
        }


def test_gate1_clienterror_classification():
    kin = _kin()
    if not _face_mounted(kin):
        _loud_skip()

    with pytest.raises(ClientError) as ei:
        kin.put_record(
            StreamName=STREAM,
            Data=b"x" * (1024 * 1024 + 1),
            PartitionKey="pk",
        )

    code = ei.value.response.get("Error", {}).get("Code", "")
    assert code == "InvalidArgumentException", f"expected InvalidArgumentException, got {code}"
    assert ei.value.response.get("ResponseMetadata", {}).get("HTTPStatusCode") == 400


def test_gate2_putrecords_order_preserved():
    kin = _kin()
    if not _face_mounted(kin):
        _loud_skip()

    bodies = [f"wf10-order-{i}".encode() for i in range(5)]

    resp = kin.put_records(
        StreamName=STREAM,
        Records=[{"Data": b, "PartitionKey": "order-pk"} for b in bodies],
    )

    assert resp["FailedRecordCount"] == 0
    results = resp["Records"]
    assert len(results) == len(bodies)
    seqs = [int(r["SequenceNumber"]) for r in results]
    assert seqs == sorted(seqs), "PutRecords results must carry ascending sequence numbers"

    records = _read_all(kin, STREAM, _shard_for("order-pk"))
    data = [r["Data"] for r in records]
    assert [b for b in bodies if b in data] == bodies, "records must read back in put order"


def test_gate3_transmute_fidelity():
    kin = _kin()
    if not _face_mounted(kin):
        _loud_skip()

    pk = f"wf10-pk-{RUN}"
    body = f"wf10-fidelity-{RUN}".encode()
    resp = kin.put_record(StreamName=STREAM, Data=body, PartitionKey=pk)

    assert resp["ShardId"] == _shard_for(pk)
    seq = int(resp["SequenceNumber"])
    assert len(resp["SequenceNumber"]) < 56  # KD-KIN-2: plain decimal

    records = _read_all(kin, STREAM, _shard_for(pk))
    ours = [r for r in records if r["Data"] == body]
    assert ours, "record not found on the KD-76-derived shard"

    seqs = [int(r["SequenceNumber"]) for r in records]
    assert seqs == sorted(seqs), "sequence numbers must ascend in read order"
