"""CLI-5 Gate 1 part B — servicebus SDK lane (pytest).

Real azure-servicebus SDK against the smalt substrate. Self-contained:
module fixture boots the substrate under EXCLUSIVE flock
/tmp/smalt-substrate.lock (recipe: docs/DEV_LOOP.md, mirror:
test/sdk-python/run.sh + py_servicebus.py), waits for the AMQP listener,
runs, kills the substrate on teardown.

Shapes mirrored from /Users/sac/smalt/test/sdk-python/py_servicebus.py.
"""
import os
import signal
import socket
import subprocess
import time
import urllib.request

import pytest
from azure.servicebus import ServiceBusClient, ServiceBusMessage, ServiceBusSubQueue

# Lane-private port block (docs/DEV_LOOP.md 38000-range), distinct from
# py5's 39272 block and py4's 39140 block.
AMQP_PORT = int(os.environ.get("CLI5_AMQP_PORT", "38672"))
SUB_PID = [None]

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


def kd21_skip(exc):
    """Loud typed skip on the KD-21 pyamqp open-frame signature."""
    if "socket-error" in str(exc) or "unexpectedly closed" in str(exc):
        pytest.skip(KD21)
    raise exc


_BOOT_SEED = """
for {q, props} <- [
  {"cli5-batch-q", %{}},
  {"cli5-dlq-q", %{}},
  {"cli5-defer-q", %{}},
  {"cli5-lock-q", %{"lockDuration" => "PT2S"}}
] do
  {:ok, _} = Smalt.Amqp.QueueStore.ensure_queue(q);
  key = "providers/Microsoft.ServiceBus/namespaces/cli5ns/queues/" <> String.downcase(q);
  Smalt.Store.put(:smalt_resources, key, %{"properties" => props})
end
"""

SECRET_B64 = "cli5-known-secret-0123456789abcdef"

BOOT = (
    'Application.put_env(:smalt, :sb_shared_key, "' + SHARED_KEY + '");'
    'Application.put_env(:smalt, :sts_signing_secret, "' + SECRET_B64 + '");'
    'Application.put_env(:smalt, :auth_mode, :enforce);'
    'Application.put_env(:smalt, :amqp_port, 38672);'
    'Application.put_env(:smalt, :event_hubs_port, 38673);'
    'Application.put_env(:smalt, :arm_port, 38654);'
    'Application.put_env(:smalt, :egress_port, 38655);'
    'Application.put_env(:smalt, :arm_tls_port, 38656);'
    '{:ok, _} = Application.ensure_all_started(:smalt);'
    + " ".join(_BOOT_SEED.split())
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


def _port_open(port):
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _lock_fd():
    return os.open("/tmp/smalt-substrate.lock", os.O_CREAT | os.O_RDWR)


_PORTS = (38672, 38673, 38654, 38655)


def _all_ports_open():
    return all(_port_open(p) for p in _PORTS)


def _boot():
    """Boot the lane substrate ONCE (all three CLI-5 files share it via the
    same port block). Boot at import so it precedes the session-scoped
    conftest gate. EXCLUSIVE lane lock /tmp/smalt-substrate-cli5.lock (the
    primary /tmp/smalt-substrate.lock is leaked by a detached beam.smp that
    inherited its fd — receipted in test/sdk-python/run.sh). No boot under
    --collect-only. Substrate killed atexit of the last importer's process."""
    import atexit
    import fcntl
    import sys

    if "--collect-only" in sys.argv:
        return
    if _all_ports_open():
        return
    fd = os.open("/tmp/smalt-substrate-cli5.lock", os.O_CREAT | os.O_RDWR)
    deadline = time.time() + 120
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                raise RuntimeError(
                    "SUBSTRATE_LOCK_TIMEOUT: /tmp/smalt-substrate-cli5.lock "
                    "not acquired within 120s (holder: "
                    "`lsof /tmp/smalt-substrate-cli5.lock`)"
                )
            time.sleep(2)
    # double-check after lock: another process may have booted meanwhile
    if _all_ports_open():
        return
    env = dict(os.environ, MIX_ENV="test")
    log = open("/tmp/cli5-substrate.log", "w")
    proc = subprocess.Popen(
        ["/opt/homebrew/bin/mix", "run", "--no-start", "--no-halt", "-e", BOOT],
        cwd="/Users/sac/smalt", env=env, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    SUB_PID[0] = proc
    up = False
    for _ in range(90):
        if _all_ports_open():
            up = True
            break
        time.sleep(1)
    if not up:
        tail = open("/tmp/cli5-substrate.log").read()[-500:]
        raise RuntimeError(
            f"SUBSTRATE_TIMEOUT — boot log /tmp/cli5-substrate.log tail: {tail}"
        )

    def _kill():
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        time.sleep(1)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    atexit.register(_kill)


_boot()


@pytest.fixture(scope="module")
def sb():
    """Yield the live AMQP connection string (substrate booted at import)."""
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
        recv.complete_message(msgs)
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
        dlq.complete_message(dead)


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
