#!/usr/bin/env python3
"""pyamqp witness for the AMQP framing shim court (KD-21/KD-49).

Connects a REAL azure-servicebus ServiceBusClient (pyamqp wire tier) to the
smalt broker on a private port block, provisions a queue via the ARM surface,
then opens a sender + receiver link (this is the KD-49 attach echo witness:
pyamqp _incoming_attach requires source/target in the attach response) and
does one real send/receive/complete roundtrip.

Exit 0 = connect + attach + roundtrip succeeded.
Nonzero = failure; stdout/stderr carry the failure signature (IndexError from
pyamqp _incoming_open frame[4], "Invalid link", socket error, timeout).
"""

import os
import socket
import sys
import threading
import time

AMQP_PORT = int(os.environ.get("COURT_AMQP_PORT", "39382"))
ARM_PORT = int(os.environ.get("COURT_ARM_PORT", "39474"))

from azure.servicebus import ServiceBusClient, ServiceBusMessage  # noqa: E402
import requests  # noqa: E402

KEY = os.environ["COURT_SB_KEY"]
CONN_STR = (
    f"Endpoint=sb://127.0.0.1:{AMQP_PORT};"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    f"SharedAccessKey={KEY};UseDevelopmentEmulator=true"
)
SUB, RG, NS = "court-sub", "court-rg", "court-ns"
AV = "2021-04-01"
ARM = f"http://127.0.0.1:{ARM_PORT}"
Q = "court-kd21-q"


def arm_put(path, body):
    r = requests.put(f"{ARM}{path}", json=body, params={"api-version": AV}, timeout=10)
    assert r.status_code in (200, 201, 202), f"ARM PUT {path}: {r.status_code} {r.text[:200]}"
    return r


def provision():
    arm_put("/subscriptions/court-sub/resourceGroups/court-rg", {"location": "eastus"})
    arm_put(
        f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ServiceBus/namespaces/{NS}",
        {"location": "eastus", "skuName": "Standard"},
    )
    arm_put(
        f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ServiceBus/namespaces/{NS}/queues/{Q}",
        {"location": "eastus", "properties": {}},
    )


def witness():
    client = ServiceBusClient.from_connection_string(
        CONN_STR, retry_total=0, retry_mode="fixed", logging_enable=False, socket_timeout=15
    )
    with client:
        sender = client.get_queue_sender(Q)
        with sender:
            sender.send_messages(ServiceBusMessage(body=b"court-kd21"))
        recv = client.get_queue_receiver(Q, max_wait_time=5)
        with recv:
            msgs = recv.receive_messages(max_message_count=1, max_wait_time=10)
            assert len(msgs) == 1, f"expected 1 message, got {len(msgs)}"
            recv.complete_message(msgs[0])
    print("WITNESS_OK")


def main():
    provision()
    box = {}

    def runner():
        try:
            witness()
            box["rc"] = 0
        except BaseException as e:  # noqa: BLE001
            import traceback

            traceback.print_exc()
            box["rc"] = 1
            box["sig"] = f"{type(e).__name__}: {e}"

    th = threading.Thread(target=runner, daemon=True)
    th.start()
    th.join(75)
    if th.is_alive():
        # pyamqp keeps non-daemon I/O threads alive across sys.exit; hard-exit
        # so the court sees the timeout signature instead of a hung witness.
        print(f"WITNESS_TIMEOUT after 75s (pyamqp hung — the KD-49 signature)")
        sys.stdout.flush()
        os._exit(3)
    if box.get("rc") == 0:
        print(f"WITNESS_OK")
        sys.exit(0)
    print(f"WITNESS_FAIL sig={box.get('sig')}")
    sys.exit(1)


if __name__ == "__main__":
    main()
