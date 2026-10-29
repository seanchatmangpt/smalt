"""servicebus sub-app: queue create / send / receive.

Transport typing (honest):
  - queue CREATE rides the ARM control plane (PUT .../namespaces/:ns/queues/:q,
    Bearer from the emulator STS). The ARM PUT materializes the AMQP entity
    (arm_gateway/router.ex sb_materialize_amqp -> Amqp.QueueStore.ensure_queue).
  - send/receive ride AMQP :5672 DIRECTLY via the real azure-servicebus SDK —
    the CLI runs on-host against loopback, so NO relay is needed. The MCP
    surface (:9545) is read-only by law (sb.peek only) and cannot carry send.
"""
from __future__ import annotations

import json
import os

import typer

from .. import wire

app = typer.Typer(help="Service Bus queues (ARM mgmt + AMQP :5672 data).")

_SUBSCRIPTION_DEFAULT = "smalt-sub"


def _body_text(body) -> str:
    """SDK message body: generator | list | bytes | str -> text."""
    import collections.abc
    if isinstance(body, (collections.abc.Iterable,)) and not \
            isinstance(body, (str, bytes, bytearray, memoryview, dict)):
        parts = []
        for p in body:
            if isinstance(p, bytes):
                parts.append(p)
            elif isinstance(p, int):
                parts.append(bytes([p]))
            else:
                parts.append(str(p).encode())
        body = b"".join(parts)
    if isinstance(body, memoryview):
        body = body.tobytes()
    if isinstance(body, (bytes, bytearray)):
        return bytes(body).decode("utf-8", "replace")
    return str(body)


def _default_key() -> str:
    """Deterministic dev key: base64(sha256(hostname <> "smalt-dev-sb")) —
    the same derivation as the substrate's SasVerifier dev-key law and
    scripts/dev_env.sh, so a substrate booted without an explicit
    :sb_shared_key verifies our CBS SAS signatures."""
    import base64
    import hashlib
    import socket
    return base64.b64encode(hashlib.sha256(
        socket.gethostname().encode() + b"smalt-dev-sb").digest()).decode()


def _conn_str() -> str:
    hostport = wire.amqp_hostport()  # SMALT_AMQP, default 127.0.0.1:5672
    key = os.environ.get("SMALT_SB_SHARED_KEY", _default_key())
    return (
        f"Endpoint=sb://{hostport};"
        "SharedAccessKeyName=RootManageSharedAccessKey;"
        f"SharedAccessKey={key};UseDevelopmentEmulator=true"
    )


def _sb_client():
    try:
        from azure.servicebus import ServiceBusClient
    except ImportError:
        wire.andon(
            "servicebus data plane requires azure-servicebus "
            "(pip install 'smalt-cli[migrate]')"
        )
    return ServiceBusClient.from_connection_string(
        _conn_str(), retry_total=0, retry_mode="fixed", logging_enable=False
    )


@app.command("queue-create")
def queue_create(
    # az parity (EXPL12-3): az's `-n` is `--name` — the ENTITY name, so the
    # queue name rides `-n/--name` and the namespace moved OFF `-n` onto
    # `--namespace-name` (az long form; `--namespace`/`--ns` still accepted).
    # The old shape (POS queue name + `-n` namespace) is gone.
    name: str = typer.Option(..., "--name", "-n",
                             help="Queue name (az: az servicebus queue create -n)."),
    namespace_name: str = typer.Option(
        "cli-ns", "--namespace-name", "--namespace", "--ns",
        help="Service Bus namespace (or the cli-ns default)."),
    resource_group: str = typer.Option("cli-rg", "--resource-group", "-g"),
    subscription: str = typer.Option(_SUBSCRIPTION_DEFAULT, "--subscription", "-s"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a queue via the ARM registry face; materializes the AMQP entity."""
    queue, namespace = name, namespace_name
    base = (f"subscriptions/{subscription}/resourceGroups/{resource_group}/"
            f"providers/Microsoft.ServiceBus")
    ns_path = f"{base}/namespaces/{namespace}"
    resp = wire.arm_put(ns_path, {"location": "eastus",
                                  "sku": {"name": "Standard",
                                          "tier": "Standard"}})
    # 202 = accepted-for-provisioning (real ARM async semantics).
    wire.expect(resp, (200, 201, 202), f"namespace create {namespace}")
    resp = wire.arm_put(f"{ns_path}/queues/{queue}", {})
    wire.expect(resp, (200, 201), f"queue-create {queue}")
    wire.emit({"queue": queue, "namespace": namespace,
               "status": resp.status_code}, output, title=f"queue {queue}")


@app.command("topic-create")
def topic_create(
    # az parity (EXPL12-D): az's `-n` is `--name` — the TOPIC entity name;
    # namespace rides `--namespace-name` (az long form; `--namespace`/`--ns`
    # accepted). Built az-shaped from the start — the EXPL12-3 `-n`
    # collision class never enters this surface.
    name: str = typer.Option(..., "--name", "-n",
                             help="Topic name (az: az servicebus topic create -n)."),
    namespace_name: str = typer.Option(
        "cli-ns", "--namespace-name", "--namespace", "--ns",
        help="Service Bus namespace (or the cli-ns default)."),
    resource_group: str = typer.Option("cli-rg", "--resource-group", "-g"),
    subscription: str = typer.Option(_SUBSCRIPTION_DEFAULT, "--subscription", "-s"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a topic via the ARM registry face; materializes the AMQP entity."""
    topic, namespace = name, namespace_name
    base = (f"subscriptions/{subscription}/resourceGroups/{resource_group}/"
            f"providers/Microsoft.ServiceBus")
    ns_path = f"{base}/namespaces/{namespace}"
    resp = wire.arm_put(ns_path, {"location": "eastus",
                                  "sku": {"name": "Standard",
                                          "tier": "Standard"}})
    wire.expect(resp, (200, 201, 202), f"namespace create {namespace}")
    resp = wire.arm_put(f"{ns_path}/topics/{topic}", {})
    wire.expect(resp, (200, 201), f"topic-create {topic}")
    wire.emit({"topic": topic, "namespace": namespace,
               "status": resp.status_code}, output, title=f"topic {topic}")


@app.command("subscription-create")
def subscription_create(
    # az parity (EXPL12-D): `az servicebus topic subscription create` binds
    # `-n` to the SUBSCRIPTION entity name; the topic is a named long flag
    # (`--topic-name`), the namespace `--namespace-name` — mirroring az.
    name: str = typer.Option(..., "--name", "-n",
                             help="Subscription name (az: -n)."),
    topic_name: str = typer.Option(..., "--topic-name",
                                   help="Parent topic name (az: --topic-name)."),
    namespace_name: str = typer.Option(
        "cli-ns", "--namespace-name", "--namespace", "--ns",
        help="Service Bus namespace (or the cli-ns default)."),
    resource_group: str = typer.Option("cli-rg", "--resource-group", "-g"),
    subscription: str = typer.Option(_SUBSCRIPTION_DEFAULT, "--subscription", "-s"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a topic subscription via the ARM registry face."""
    sub_name, topic, namespace = name, topic_name, namespace_name
    base = (f"subscriptions/{subscription}/resourceGroups/{resource_group}/"
            f"providers/Microsoft.ServiceBus")
    ns_path = f"{base}/namespaces/{namespace}"
    resp = wire.arm_put(ns_path, {"location": "eastus",
                                  "sku": {"name": "Standard",
                                          "tier": "Standard"}})
    wire.expect(resp, (200, 201, 202), f"namespace create {namespace}")
    resp = wire.arm_put(f"{ns_path}/topics/{topic}", {})
    wire.expect(resp, (200, 201), f"topic-create {topic}")
    resp = wire.arm_put(f"{ns_path}/topics/{topic}/subscriptions/{sub_name}", {})
    wire.expect(resp, (200, 201), f"subscription-create {sub_name}")
    wire.emit({"subscription": sub_name, "topic": topic,
               "namespace": namespace, "status": resp.status_code},
              output, title=f"subscription {sub_name}")


@app.command("send")
def send(
    queue: str = typer.Argument(...),
    message: str = typer.Argument(...),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Send a message over AMQP :5672 (direct; no relay)."""
    from azure.servicebus import ServiceBusMessage

    with _sb_client() as client:
        sender = client.get_queue_sender(queue_name=queue)
        with sender:
            sender.send_messages(ServiceBusMessage(message))
    wire.emit({"queue": queue, "sent": message, "transport": "amqp:5672"},
              output, title=f"send {queue}")


@app.command("receive")
def receive(
    queue: str = typer.Argument(...),
    max_messages: int = typer.Option(1, "--max", "-m"),
    timeout: int = typer.Option(5, "--wait", "-w", help="Receive wait seconds."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Receive (and settle) messages over AMQP :5672."""
    from azure.servicebus import ServiceBusSubQueue

    msgs = []
    with _sb_client() as client:
        receiver = client.get_queue_receiver(queue_name=queue)
        with receiver:
            batch = receiver.receive_messages(
                max_message_count=max_messages,
                max_wait_time=timeout,  # SDK-internal scheduling wait, not a
            )                           # coordination sleep.
            for m in batch:
                text = _body_text(m.body)
                try:
                    parsed = json.loads(text)
                except ValueError:
                    parsed = text
                msgs.append({"sequence": m.sequence_number, "body": parsed})
                receiver.complete_message(m)
    if not msgs:
        wire.emit([], output, title="no messages")
        return
    wire.emit(msgs, output, title=f"receive {queue}")


@app.command("peek-dead-letter")
def peek_dead_letter(
    queue: str = typer.Argument(...),
    max_messages: int = typer.Option(10, "--max", "-m"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Peek the dead-letter subqueue (read-only)."""
    from azure.servicebus import ServiceBusSubQueue

    msgs = []
    with _sb_client() as client:
        receiver = client.get_queue_receiver(
            queue_name=queue, sub_queue=ServiceBusSubQueue.DEAD_LETTER)
        with receiver:
            batch = receiver.peek_messages(max_message_count=max_messages)
            for m in batch:
                msgs.append({"sequence": m.sequence_number,
                             "body": _body_text(m.body)})
    wire.emit(msgs, output, title=f"dlq {queue}")
