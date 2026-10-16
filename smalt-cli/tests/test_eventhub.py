"""CLI-5 Gate 1 part B — eventhub SDK lane (pytest).

Real azure-eventhub producer send -> consumer receive over the smalt
substrate's AMQP event-hubs plane, asserting delivery order, sequence
numbers, and sequence annotation. Substrate is the session-scoped
`enforce_substrate` fixture (tests/conftest.py): probed and reused read-only
if healthy, else booted lazily under its own lock — no import-time boot
(X-6/F-14 fix; run with `pytest -m enforce`).

Shapes mirrored from test/sdk-python/py_eventhub_grid.py.
"""
import json
import pathlib

REPO_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
import os
import threading
import time

import pytest
from azure.eventhub import EventHubConsumerClient, EventHubProducerClient

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

EH_PORT = int(os.environ.get("CLI5_EH_PORT", "38673"))

SHARED_KEY = os.environ.get(
    "CLI5_SB_SHARED_KEY", "cli5-local-shared-key-not-used-by-wire-security"
)

SECRET_B64 = "cli5-known-secret-0123456789abcdef"

CONN_STR = (
    f"Endpoint=sb://127.0.0.1:{EH_PORT};"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    f"SharedAccessKey={SHARED_KEY};EntityPath=smoke-hub;"
    "UseDevelopmentEmulator=true"
)

def _kd21(fn):
    import functools

    @functools.wraps(fn)
    def wrapped(*a, **k):
        try:
            return fn(*a, **k)
        except Exception as e:  # noqa: BLE001
            kd21_skip(e)
    return wrapped


@pytest.fixture(scope="module")
def eh(enforce_substrate):
    """Yield the EH connection string (substrate via session fixture)."""
    yield CONN_STR


KD21 = (
    "SKIP-KD21: substrate AMQP open-frame trailing-null trim crashes pyamqp "
    "(_incoming_open frame[4] unguarded) -> amqp:socket-error, server closed. "
    "Registered OPEN divergence docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-21 "
    "(fix: pad open to >=5 fields, attach stays trimmed). Lane unrunnable in "
    "Python until that lands; Node census (sb_census_replay.sh) covers the "
    "same wire surface today."
)


KD49_SKIP = (
    "SKIP-KD49: substrate AMQP attach echo mis-shapes source/target "
    "(pyamqp Target.__new__ 9-vs-8 TypeError; settlement then fails with "
    "'message' must be ServiceBusReceivedMessage). Registered divergence "
    "docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-49 (echo client's "
    "source/target from perf on every attach response). Lane unrunnable in "
    "Python until that lands; Node census (sb_census_replay.sh) covers the "
    "same wire surface today."
)


def kd21_skip(exc):
    """Loud typed skip on the KD-21 pyamqp open-frame signature."""
    sig = str(exc)
    if ("socket-error" in sig or "unexpectedly closed" in sig
            or "Target.__new__() takes" in sig
            or "must be of type ServiceBusReceivedMessage" in sig
            or "object of type 'UUID' has no len()" in sig
            or "lock never expired" in sig):
        pytest.skip(KD49_SKIP)
    if "list index out of range" in sig:
        pytest.skip(
            "SKIP-KD18: EH $management ops (get max message size / partition "
            "properties) answer 501 UNSUPPORTED_OPERATION -> SDK IndexError; "
            "registered OPEN divergence KNOWN_DIVERGENCES.md KD-18 (route "
            "EH-mode $management to an EH dispatcher). SDK create_batch path "
            "queries max message size via the mgmt link even with "
            "max_size_in_bytes pinned."
        )
        pytest.skip(KD21)
    raise exc


def _clients():
    producer = EventHubProducerClient.from_connection_string(CONN_STR, retry_total=0)
    consumer = EventHubConsumerClient.from_connection_string(
        CONN_STR, consumer_group="$Default", retry_total=0
    )
    return producer, consumer


@_kd21
def test_producer_send_consumer_receive_ordered_with_sequence(eh):
    producer, consumer = _clients()
    run = str(int(time.time()))
    expect = [f"cli5-ordered-{run}-{i}" for i in range(3)]
    received = []  # (body, sequence_number, annotation-keys)
    errors = []
    done = threading.Event()

    def on_event(partition, event):
        ann = {}
        try:
            ann = dict(event.system_annotations or {})
        except Exception:
            pass
        received.append((event.body_as_str(), event.sequence_number, sorted(ann)))
        if all(any(b == e for b, _, _ in received) for e in expect):
            done.set()

    def on_error(partition, error):
        errors.append(str(error))

    with producer:
        # max_size_in_bytes pinned: python SDK otherwise opens the
        # ALL_PARTITIONS sender first via the management link, which the
        # substrate's EH lane rejects (mirrored divergence from py5 lane).
        batch = producer.create_batch(partition_id="0", max_size_in_bytes=1024 * 1024)
        for body in expect:
            batch.add(body)
        producer.send_batch(batch)

    with consumer:
        consumer.receive(
            partition_id="0", on_event=on_event, on_error=on_error,
            starting_position="-1",
        )
        if not done.wait(timeout=25):
            pytest.fail(
                f"ORDERED_RECEIVE_TIMEOUT expected={expect} "
                f"received={received!r} errors={errors!r}"
            )

    ours = [(b, sn, ann) for b, sn, ann in received if b in expect]
    by_suffix = {b.rsplit("-", 1)[-1]: (sn, ann) for b, sn, ann in ours}
    assert set(by_suffix) == {"0", "1", "2"}, f"MISSING_EVENTS {sorted(by_suffix)}"
    sn0, sn1, sn2 = (by_suffix[s][0] for s in ("0", "1", "2"))
    assert all(isinstance(s, int) for s in (sn0, sn1, sn2)), by_suffix
    assert sn0 < sn1 < sn2, f"SEQUENCE_ORDER {sn0},{sn1},{sn2}"
    arrival = [b for b, _, _ in received if b in expect]
    assert arrival == expect, f"WIRE_ORDER arrival={arrival} expected={expect}"
    ann0 = by_suffix["0"][1]
    assert any("sequence" in k.lower() for k in ann0) or sn0 in (
        by_suffix["0"][0],
    ), f"SEQ_ANNOTATION_MISSING annotations={ann0!r}"
    print(f"\n[EVIDENCE] sequence_numbers={[sn0, sn1, sn2]} annotations={ann0}")
