#!/usr/bin/env python3
"""PY-4 lane: real azure-servicebus SDK probes against the smalt substrate.

Boots nothing itself — the substrate must already be listening on
AMQP_PORT/ARM_PORT with SMALT_SB_SHARED_KEY as the broker shared key.
Run via: test/sdk-python/.venv-sb/bin/python test/sdk-python/py_servicebus.py
"""
import os
import sys
import json
import threading
import time
import traceback

from azure.servicebus import (  # noqa: E402
    ServiceBusClient,
    ServiceBusMessage,
    ServiceBusSubQueue,
)
from azure.servicebus.management import ServiceBusAdministrationClient  # noqa: E402

AMQP_PORT = int(os.environ.get("SMALT_PY_AMQP_PORT", "39140"))
ARM_PORT = int(os.environ.get("SMALT_PY_ARM_PORT", "39141"))
ARM_TLS_PORT = int(os.environ.get("SMALT_PY_ARM_TLS_PORT", "39143"))
HERE = os.path.dirname(os.path.abspath(__file__))
KEY = os.environ.get(
    "SMALT_SB_SHARED_KEY", open(os.path.join(HERE, ".logs", "key.txt")).read().strip()
)
CONN_STR = (
    f"Endpoint=sb://127.0.0.1:{AMQP_PORT};"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    f"SharedAccessKey={KEY};UseDevelopmentEmulator=true"
)

CLIENT_KWARGS = dict(
    retry_total=0, retry_mode="fixed", logging_enable=False, socket_timeout=15
)

# The Python ServiceBusAdministrationClient is a management-plane client that
# hardcodes https:// and the ARM-shaped URL space; it cannot create entities on
# the substrate's Service Bus data plane. Divergence receipt: PUT /{entity}
# (Python admin shape) -> 404 RouteNotFound from the ARM catch-all; the
# substrate's queue registry is fed by ARM child PUTs
# .../Microsoft.ServiceBus/namespaces/{ns}/queues/{name} (api-version
# 2021-04-01), which QueueStore.queue_settings/1 reads for
# requires_session/lock_duration/max_delivery_count. Provisioning therefore
# goes through that admitted ARM surface with plain requests (real HTTP
# collaborator), and the SDK exercises the AMQP data plane.
import requests

ARM = f"http://127.0.0.1:{ARM_PORT}"
SUB, RG, NS = "py4-sub", "py4-rg", "py4-ns"
AV = "2021-04-01"
ARM_BASE = (
    f"{ARM}/subscriptions/{SUB}/resourceGroups/{RG}/providers/"
    f"Microsoft.ServiceBus/namespaces/{NS}/queues"
)


def arm_put(path, body):
    r = requests.put(
        f"{ARM}{path}",
        json=body,
        params={"api-version": AV},
        timeout=10,
    )
    assert r.status_code in (200, 201), f"ARM PUT {path}: {r.status_code} {r.text[:200]}"
    return r


def provision_queue(name, props):
    ensure_namespace()
    arm_put(
        f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ServiceBus/namespaces/{NS}/queues/{name}",
        {"location": "eastus", "properties": props},
    )
    return name


def ensure_namespace():
    global _NS_READY
    if _NS_READY:
        return
    arm_put("/subscriptions/py4-sub/resourceGroups/py4-rg", {"location": "eastus"})
    arm_put(
        f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ServiceBus/namespaces/{NS}",
        {"location": "eastus", "skuName": "Standard"},
    )
    _NS_READY = True


_NS_READY = False


def make_queue(admin_unused, name, **props):
    return provision_queue(name, props)


RESULTS = []


PROBE_TIMEOUT_S = 90


def probe(name):
    def deco(fn):
        def wrapped():
            box = {}

            def runner():
                t0 = time.time()
                try:
                    box["detail"] = fn() or "ok"
                    box["status"] = "PASS"
                except Exception as e:  # noqa: BLE001
                    box["status"] = "FAIL"
                    box["detail"] = f"{type(e).__name__}: {e}"
                    traceback.print_exc()

            th = threading.Thread(target=runner, daemon=True)
            th.start()
            th.join(PROBE_TIMEOUT_S)
            if th.is_alive():
                # pyamqp can block indefinitely when the broker's attach echo
                # lacks source/target (see header note); bound each probe.
                box["status"] = "FAIL"
                box["detail"] = f"TIMEOUT after {PROBE_TIMEOUT_S}s (probe thread hung)"
            RESULTS.append((name, box.get("status"), box.get("detail"), PROBE_TIMEOUT_S))
            print(f"[{box.get('status')}] {name}: {box.get('detail')}")

        wrapped.__name__ = fn.__name__
        return wrapped

    return deco


def make_queue(name, **props):
    return provision_queue(name, props)
    return name


@probe("send_receive_batch_complete")
def p_send_receive():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-batch-q")
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            sender.send_messages(
                [ServiceBusMessage(body=f"m{i}".encode()) for i in range(5)]
            )
        recv = client.get_queue_receiver(q, max_wait_time=5)
        with recv:
            msgs = recv.receive_messages(max_message_count=5, max_wait_time=10)
            assert len(msgs) == 5, f"expected 5, got {len(msgs)}"
            bodies = sorted(str(m) for m in msgs)
            assert bodies == [f"m{i}" for i in range(5)], bodies
            recv.complete_message(msgs)
            # queue must now be empty
            again = recv.receive_messages(max_message_count=5, max_wait_time=2)
            assert again == [], f"queue not drained: {again}"
    return f"5/5 batch round-trip on {q}"


@probe("peek")
def p_peek():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-peek-q")
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            sender.send_messages([ServiceBusMessage(body=f"p{i}".encode()) for i in range(3)])
        recv = client.get_queue_receiver(q, max_wait_time=5)
        with recv:
            peeked = recv.peek_messages(max_message_count=3)
            assert len(peeked) == 3, f"peek got {len(peeked)}"
            assert [str(m) for m in peeked] == ["p0", "p1", "p2"], [str(m) for m in peeked]
            # peek does not lock or consume
            still = recv.peek_messages(max_message_count=10)
            assert len(still) == 3, f"peek is destructive: {len(still)}"
            msgs = recv.receive_messages(max_message_count=3, max_wait_time=5)
            assert len(msgs) == 3, "peek consumed the messages"
            recv.complete_message(msgs)
    return "peek 3, non-destructive, then receive+complete 3"


@probe("abandon_requeues")
def p_abandon():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-abandon-q")
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            sender.send_messages(ServiceBusMessage(body=b"retry-me"))
        recv = client.get_queue_receiver(q, max_wait_time=5)
        with recv:
            m1 = recv.receive_messages(max_message_count=1, max_wait_time=10)[0]
            recv.abandon_message(m1)
            m2 = recv.receive_messages(max_message_count=1, max_wait_time=10)[0]
            assert m2.delivery_count >= 1, f"delivery_count={m2.delivery_count}"
            assert str(m2) == "retry-me"
            recv.complete_message(m2)
    return f"abandon re-delivered, delivery_count incremented to {m2.delivery_count}"


@probe("dead_letter_surface")
def p_dead_letter():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-dlq-q")
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            msg = ServiceBusMessage(body=b"poison", application_properties={"lane": "PY-4"})
            sender.send_messages(msg)
        recv = client.get_queue_receiver(q, max_wait_time=5)
        with recv:
            m = recv.receive_messages(max_message_count=1, max_wait_time=10)[0]
            recv.dead_letter_message(
                m,
                reason="py4-court",
                error_description="intentional dead-letter probe",
            )
        dlq = client.get_queue_receiver(
            q, sub_queue=ServiceBusSubQueue.DEAD_LETTER, max_wait_time=5
        )
        with dlq:
            dead = dlq.receive_messages(max_message_count=5, max_wait_time=10)
            assert dead, "DLQ empty"
            d = [x for x in dead if str(x) == "poison"][0]
            assert (
                d.dead_letter_reason == "py4-court"
            ), f"reason={d.dead_letter_reason!r}"
            assert (
                d.dead_letter_error_description == "intentional dead-letter probe"
            ), f"desc={d.dead_letter_error_description!r}"
            dlq.complete_message(dead)
    return f"dead-letter reason+description round-trip on {q}"

@probe("defer_receive_by_sequence")
def p_defer():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-defer-q")
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            sender.send_messages(ServiceBusMessage(body=b"later"))
        recv = client.get_queue_receiver(q, max_wait_time=5)
        with recv:
            m = recv.receive_messages(max_message_count=1, max_wait_time=10)[0]
            seq = m.sequence_number
            recv.defer_message(m)
            # not receivable normally while deferred
            none = recv.receive_messages(max_message_count=5, max_wait_time=2)
            assert none == [], f"deferred message was redelivered normally: {none}"
            got = recv.receive_deferred_messages([seq])
            assert len(got) == 1 and str(got[0]) == "later", got
            recv.complete_message(got[0])
    return f"defer + receive_deferred_messages(seq={seq}) + complete"


@probe("session_roundtrip")
def p_session():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-session-q", requires_session=True)
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            sender.send_messages(
                ServiceBusMessage(body=b"s1-msg", session_id="py4-sess")
            )
        recv = client.get_queue_receiver(q, session_id="py4-sess", max_wait_time=5)
        with recv:
            msgs = recv.receive_messages(max_message_count=5, max_wait_time=10)
            assert len(msgs) == 1, msgs
            assert str(msgs[0]) == "s1-msg"
            assert str(msgs[0].session_id) == "py4-sess"
            recv.complete_message(msgs)
    return "requires_session queue: session send + accept + complete"


@probe("lock_expiry_PT2S")
def p_lock_expiry():
    client = ServiceBusClient.from_connection_string(CONN_STR, **CLIENT_KWARGS)
    pass  # queues provisioned via ARM surface
    q = make_queue("py4-lock-q", lock_duration="PT2S")
    settings = requests.get(
        f"{ARM_BASE}/{q}", params={"api-version": AV}, timeout=10
    ).json()["properties"].get("lockDuration") or json.loads(json.dumps(requests.get(
        f"{ARM_BASE}/{q}", params={"api-version": AV}, timeout=10
    ).json()))["properties"].get("lock_duration")
    with client:
        sender = client.get_queue_sender(q)
        with sender:
            sender.send_messages(ServiceBusMessage(b"lock-me"))
        r1 = client.get_queue_receiver(q, max_wait_time=5, max_auto_lock_renewal_duration=0)
        with r1:
            m1 = r1.receive_messages(max_message_count=1, max_wait_time=10)[0]
            # hold the lock without renewing; it must expire after 2s
            time.sleep(3.5)
            r2 = client.get_queue_receiver(
                q, max_wait_time=5, max_auto_lock_renewal_duration=0
            )
            with r2:
                m2 = r2.receive_messages(max_message_count=5, max_wait_time=10)
                assert m2, "lock never expired: second receiver got nothing"
                assert str(m2[0]) == "lock-me"
                r2.complete_message(m2[0])
    return f"PT2S lock expired: message re-delivered to second receiver (runtime lock_duration={settings})"


def main():
    print(f"target: {CONN_STR.split(';')[0]}")
    for fn in (
        p_send_receive,
        p_peek,
        p_abandon,
        p_dead_letter,
        p_defer,
        p_session,
        p_lock_expiry,
    ):
        fn()
    print("\n=== SUMMARY ===")
    fails = 0
    for name, status, detail, dur in RESULTS:
        print(f"{status}  {name} ({dur:.1f}s) — {detail}")
        fails += status == "FAIL"
    total = len(RESULTS)
    print(f"TOTAL {total - fails}/{total} PASS")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
