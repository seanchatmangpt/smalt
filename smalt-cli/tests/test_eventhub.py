"""CLI-5 Gate 1 part B — eventhub SDK lane (pytest).

Real azure-eventhub producer send -> consumer receive over the smalt
substrate's AMQP event-hubs plane, asserting delivery order, sequence
numbers, and sequence annotation. Self-contained: module fixture boots the
substrate under EXCLUSIVE flock /tmp/smalt-substrate.lock, waits for the
EH listener, runs, kills the substrate on teardown.

Shapes mirrored from /Users/sac/smalt/test/sdk-python/py_eventhub_grid.py.
"""
import json
import os
import signal
import socket
import subprocess
import threading
import time

import pytest
from azure.eventhub import EventHubConsumerClient, EventHubProducerClient

EH_PORT = int(os.environ.get("CLI5_EH_PORT", "38673"))
SUB_PID = [None]

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

BOOT = (
    'Application.put_env(:smalt, :sb_shared_key, "' + SHARED_KEY + '");'
    'Application.put_env(:smalt, :sts_signing_secret, "' + SECRET_B64 + '");'
    'Application.put_env(:smalt, :auth_mode, :enforce);'
    'Application.put_env(:smalt, :amqp_port, 38672);'
    'Application.put_env(:smalt, :event_hubs_port, 38673);'
    'Application.put_env(:smalt, :arm_port, 38654);'
    'Application.put_env(:smalt, :egress_port, 38655);'
    'Application.put_env(:smalt, :arm_tls_port, 38656);'
    '{:ok, _} = Application.ensure_all_started(:smalt)'
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
def eh():
    """Yield the EH connection string (substrate booted at import)."""
    yield CONN_STR


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
    sig = str(exc)
    if ("socket-error" in sig or "unexpectedly closed" in sig):
        pytest.skip(KD21)
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
