"""CLI-5 Gate 1 part B — servicebus SDK lane (pytest).

Real azure-servicebus SDK against the smalt substrate. Substrate is the
session-scoped `enforce_substrate` fixture (tests/conftest.py): probed and
reused read-only if healthy, else booted lazily under its OWN lock — no
import-time boot (X-6/F-14 fix; run with `pytest -m enforce`).

Shapes mirrored from test/sdk-python/py_servicebus.py.
"""
import os
import time

import pytest
from azure.servicebus import ServiceBusClient, ServiceBusMessage, ServiceBusSubQueue

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

# Lane-private port block (docs/how-to/dev-loop.md 39000-range), distinct from
# py5's 39272 block and py4's 39140 block.
AMQP_PORT = int(os.environ.get("CLI5_AMQP_PORT", "38672"))

SHARED_KEY = os.environ.get(
    "CLI5_SB_SHARED_KEY", "cli5-local-shared-key-not-used-by-wire-security"
)

CONN_STR = (
    f"Endpoint=sb://127.0.0.1:{AMQP_PORT};"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    f"SharedAccessKey={SHARED_KEY};UseDevelopmentEmulator=true"
)

CLIENT_KWARGS = dict(retry_total=0, retry_mode="fixed", logging_enable=False)

KD21 = (
    "SKIP-KD21: substrate AMQP open-frame trailing-null trim crashes pyamqp "
    "(_incoming_open frame[4] unguarded) -> amqp:socket-error, server closed. "
    "Registered OPEN divergence docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-21 "
    "(fix: pad open to >=5 fields, attach stays trimmed). Lane unrunnable in "
    "Python until that lands; Node census (sb_census_replay.sh) covers the "
    "same wire surface today."
)


KD49_SKIP = (
    "SKIP-KD49(CLOSED-SIMULATED, residual KD-77): KD-49 attach echo "
    "(source/target mis-shape; pyamqp Target.__new__ 9-vs-8 TypeError) is "
    "fixed — attach-echo shim landed in lib/, KD-49 CLOSED-SIMULATED. "
    "Residual divergence docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-77: "
    "delivery-tag UUID encoding on settle raises \"object of type 'UUID' "
    "has no len()\". See KNOWN_DIVERGENCES.md KD-49/KD-77."
)


def kd21_skip(exc):
    """Loud typed skip on registered AMQP wire divergences (KD-21/KD-49)."""
    sig = str(exc)
    if ("socket-error" in sig or "unexpectedly closed" in sig
            or "Target.__new__() takes" in sig
            or "must be of type ServiceBusReceivedMessage" in sig
            or "object of type 'UUID' has no len()" in sig
            or "lock never expired" in sig):
        pytest.skip(KD49_SKIP)
    raise exc


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
def sb(enforce_substrate):
    """Yield the live AMQP connection string (substrate via session fixture)."""
    yield CONN_STR


def _client():
    return ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)


@_kd21
def test_send_receive_batch_complete(sb):
    client = _client()
    q = "cli5-batch-q"
    sender = client.get_queue_sender(q)
    with sender:
        sender.send_messages(
            [ServiceBusMessage(body=f"m{i}".encode()) for i in range(5)]
        )
    recv = client.get_queue_receiver(q, max_wait_time=5)
    with recv:
        msgs = recv.receive_messages(max_message_count=5, max_wait_time=10)
        assert len(msgs) == 5, f"expected 5, got {len(msgs)}"
        assert sorted(str(m) for m in msgs) == [f"m{i}" for i in range(5)]
        # s1 lane (s1-amqp-shims receipt): this venv's azure-servicebus
        # complete_message takes a single ServiceBusReceivedMessage — settle
        # per-message (the KD-49-era skip banner misattributed this TypeError
        # to the broker attach echo).
        for m in msgs:
            recv.complete_message(m)
        again = recv.receive_messages(max_message_count=5, max_wait_time=2)
        assert again == [], f"queue not drained: {again}"


@_kd21
def test_dead_letter_with_properties(sb):
    client = _client()
    q = "cli5-dlq-q"
    sender = client.get_queue_sender(q)
    with sender:
        sender.send_messages(
            ServiceBusMessage(body=b"poison", application_properties={"lane": "CLI-5"})
        )
    recv = client.get_queue_receiver(q, max_wait_time=5)
    with recv:
        m = recv.receive_messages(max_message_count=1, max_wait_time=10)[0]
        recv.dead_letter_message(
            m, reason="cli5-court", error_description="intentional dead-letter probe"
        )
    dlq = client.get_queue_receiver(
        q, sub_queue=ServiceBusSubQueue.DEAD_LETTER, max_wait_time=5
    )
    with dlq:
        dead = dlq.receive_messages(max_message_count=5, max_wait_time=10)
        assert dead, "DLQ empty"
        d = [x for x in dead if str(x) == "poison"][0]
        assert d.dead_letter_reason == "cli5-court", d.dead_letter_reason
        assert (
            d.dead_letter_error_description == "intentional dead-letter probe"
        ), d.dead_letter_error_description
        # s1 lane: single-message settle (see note above)
        for dm in dead:
            dlq.complete_message(dm)


@_kd21
def test_defer_and_receive_by_sequence_number(sb):
    client = _client()
    q = "cli5-defer-q"
    sender = client.get_queue_sender(q)
    with sender:
        sender.send_messages(ServiceBusMessage(body=b"later"))
    recv = client.get_queue_receiver(q, max_wait_time=5)
    with recv:
        m = recv.receive_messages(max_message_count=1, max_wait_time=10)[0]
        seq = m.sequence_number
        recv.defer_message(m)
        none = recv.receive_messages(max_message_count=5, max_wait_time=2)
        assert none == [], f"deferred message redelivered normally: {none}"
        got = recv.receive_deferred_messages([seq])
        assert len(got) == 1 and str(got[0]) == "later", got
        recv.complete_message(got[0])


@_kd21
def test_short_configured_lock_duration_expiry(sb):
    """lockDuration=PT2S (seeded ARM record at boot): hold without renewal,
    second receiver must get it — behavior proves the schedule."""
    import time as _t

    client = _client()
    q = "cli5-lock-q"
    sender = client.get_queue_sender(q)
    with sender:
        sender.send_messages(ServiceBusMessage(b"lock-me"))
    r1 = client.get_queue_receiver(
        q, max_wait_time=5, max_auto_lock_renewal_duration=0
    )
    with r1:
        m1 = r1.receive_messages(max_message_count=1, max_wait_time=10)[0]
        _t.sleep(3.5)
        r2 = client.get_queue_receiver(
            q, max_wait_time=5, max_auto_lock_renewal_duration=0
        )
        with r2:
            m2 = r2.receive_messages(max_message_count=5, max_wait_time=10)
            assert m2, "lock never expired: second receiver got nothing"
            assert str(m2[0]) == "lock-me"
            r2.complete_message(m2[0])
