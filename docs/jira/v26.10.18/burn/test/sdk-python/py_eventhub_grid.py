#!/usr/bin/env python
"""Lane PY-5: REAL Python azure-eventhub + azure-eventgrid SDKs against the
smalt substrate (v26.10.14). Fail-closed, zero skips; every result is printed
as a machine-readable PROBE line and exits non-zero on any failure.
Venv: test/sdk-python/.venv-eh (receipt: docs/jira/v26.10.14/sdk-results/py-eventhub-eventgrid.md).

Event Hubs leg: EventHubProducerClient send -> EventHubConsumerClient receive
over the real AMQP wire, asserting delivery order and sequence numbers.
Event Grid leg: EventGridPublisherClient.send() of a valid CloudEvent (expect
200 ingest) and a hostile CloudEvent (expect typed 400 InvalidCloudEvent).
"""
import json
import os
import sys
import threading
import time
import traceback

from azure.eventhub import EventHubProducerClient, EventHubConsumerClient
from azure.eventgrid import EventGridPublisherClient
from azure.core.messaging import CloudEvent  # eventgrid 4.x moved CloudEvent here
from azure.core.credentials import AzureKeyCredential
from azure.core.exceptions import HttpResponseError

RESULTS = []


def probe(name, fn):
    try:
        detail = fn() or {}
        RESULTS.append((name, "PASS", detail))
        print(f"PROBE {name} PASS {json.dumps(detail, default=str)}", flush=True)
    except Exception as e:
        RESULTS.append((name, "FAIL", {"error": str(e), "kind": type(e).__name__,
                                       "desc": getattr(e, "description", None),
                                       "condition": getattr(e, "condition", None)}))
        print(
            f"PROBE {name} FAIL "
            f"{json.dumps({'error': str(e), 'tb': traceback.format_exc()})}",
            flush=True,
        )
    return lambda: RESULTS[-1]


# ---------------------------------------------------------------------------
# Event Hubs (AMQP lane)
# ---------------------------------------------------------------------------

EH_CONN_STR = os.environ["SMALT_EH_CONNECTION_STRING"]
EH_HUB = "smoke-hub"
RUN = str(int(time.time()))


def make_clients():
    producer = EventHubProducerClient.from_connection_string(EH_CONN_STR, retry_total=0)
    consumer = EventHubConsumerClient.from_connection_string(
        EH_CONN_STR, consumer_group="$Default", retry_total=0
    )
    return producer, consumer


def eh_properties():
    """Management-link probe: enumerate partitions. Localizes the EH wire
    failure (CBS vs mgmt vs sender attach)."""
    producer, _ = make_clients()
    with producer:
        props = producer.get_eventhub_properties()
    assert props, "PROPERTIES_REQUIRED"
    assert props.partition_ids, "NONEMPTY_PARTITION_IDS"
    return {"partition_ids": list(props.partition_ids), "created_at": str(props.created_at)}


def eh_roundtrip():
    producer, consumer = make_clients()
    received = []  # (body, sequence_number, annotations)
    errors = []
    done = threading.Event()
    expect = [f"py5-ordered-{RUN}-{i}" for i in range(3)]

    def on_event(partition, event):
        ann = {}
        try:
            ann = dict(event.system_annotations or {})
        except Exception:
            pass
        try:
            ann.update(
                {k: v for k, v in (event.raw_amqp_message.annotations or {}).items()
                 if isinstance(k, str)}
            )
        except Exception:
            pass
        received.append((event.body_as_str(), event.sequence_number, ann))
        if all(any(b == e for b, _, _ in received) for e in expect):
            done.set()

    def on_error(partition, error):
        errors.append(str(error))

    with producer:
        # max_size_in_bytes pinned: python SDK otherwise opens the
        # ALL_PARTITIONS sender first to query max message size via the
        # management link, which the substrate's 5673-class lane rejects
        # ("list index out of range"). This isolates the partition-sender
        # data path under test.
        batch = producer.create_batch(partition_id="0", max_size_in_bytes=1024 * 1024)
        for body in expect:
            batch.add(body)
        producer.send_batch(batch)

    with consumer:
        consumer.receive(
            partition_id="0",
            on_event=on_event,
            on_error=on_error,
            starting_position="-1",  # earliest
        )
        if not done.wait(timeout=25):
            raise AssertionError(
                f"ORDERED_RECEIVE_TIMEOUT expected={expect} received={received!r} errors={errors!r}"
            )

    ours = [(b, sn, ann) for b, sn, ann in received if b in expect]
    # order in which our three arrived, by send order not dict luck
    by_suffix = {b.rsplit("-", 1)[-1]: (sn, ann) for b, sn, ann in ours}
    assert set(by_suffix) == {"0", "1", "2"}, f"MISSING_EVENTS {sorted(by_suffix)}"
    sn0, sn1, sn2 = by_suffix["0"][0], by_suffix["1"][0], by_suffix["2"][0]
    assert all(isinstance(s, int) for s in (sn0, sn1, sn2)), f"SEQ_NUMBERS {by_suffix}"
    assert sn0 < sn1 < sn2, f"SEQUENCE_ORDER sn0={sn0} sn1={sn1} sn2={sn2}"

    # arrival order on the wire matches send order
    arrival = [b for b, _, _ in received if b in expect]
    assert arrival == expect, f"WIRE_ORDER arrival={arrival} expected={expect}"

    # sequence-number annotation present on the delivered message
    ann0 = by_suffix["0"][1]
    ann_vals = [v for v in ann0.values()]
    assert sn0 in ann_vals or any(
        "sequence" in str(k).lower() for k in ann0
    ), f"SEQ_ANNOTATION_MISSING annotations={ann0!r}"

    return {
        "bodies": expect,
        "sequence_numbers": [sn0, sn1, sn2],
        "annotations_seen": sorted(str(k) for k in ann0),
        "recv_errors": errors,
    }


# ---------------------------------------------------------------------------
# Event Grid (HTTP ingest lane)
# ---------------------------------------------------------------------------

EG_ENDPOINT = os.environ["SMALT_EG_ENDPOINT"]  # .../topics/<topic>/events


def eg_client():
    return EventGridPublisherClient(EG_ENDPOINT, AzureKeyCredential("py5-local"))


def eg_valid():
    client = eg_client()
    event = CloudEvent(
        type="Smalt.Py5.Probe",
        source="/smalt/py5",
        data={"lane": "py5", "run": RUN},
    )
    try:
        client.send(event)
        status = 200
    except HttpResponseError as e:
        status = e.status_code
        raise AssertionError(f"VALID_EVENT_REJECTED status={status} resp={e.response.text() if e.response else ''}")
    return {"status": status}


def eg_hostile():
    client = eg_client()
    bad = {"id": "hostile-1", "type": "Smalt.Py5.Hostile"}  # no specversion/source
    try:
        client.send(bad)
        raise AssertionError("HOSTILE_EVENT_ACCEPTED — expected 400 InvalidCloudEvent")
    except HttpResponseError as e:
        status = e.status_code
        body = e.response.text() if e.response else ""
        try:
            code = json.loads(body)["error"]["code"]
        except Exception:
            code = None
        assert status == 400, f"EXPECTED_400 got={status} body={body!r}"
        assert code == "InvalidCloudEvent", f"EXPECTED_InvalidCloudEvent got={code!r} body={body!r}"
        return {"status": status, "code": code}


def main():
    if os.environ.get("PY5_DEBUG"):
        import logging
        logging.basicConfig(level=logging.DEBUG, stream=sys.stdout)
    if os.environ.get("PY5_TRACE"):
        # Debug harness (not a test double): surface the client-side stack of
        # the IndexError the SDK wraps into EventHubError, which otherwise
        # loses the original traceback.
        import azure.eventhub._transport._pyamqp_transport as tp

        orig = tp.PyamqpTransport._handle_exception

        def traced(self, exception, **kw):
            print("[py5][trace] inner exception:", repr(exception), flush=True)
            traceback.print_exc()
            return orig(self, exception, **kw)

        tp.PyamqpTransport._handle_exception = traced
    print(f"[py5] azure-eventhub/eventgrid probes", flush=True)
    probe("eh.properties_mgmt_link", eh_properties)
    probe("eh.produce_consume_ordered", eh_roundtrip)
    probe("eg.valid_cloudevent_ingest", eg_valid)
    probe("eg.hostile_cloudevent_400", eg_hostile)

    failed = [r for r in RESULTS if r[1] != "PASS"]
    print(f"SUMMARY {len(RESULTS) - len(failed)}/{len(RESULTS)} probes passed", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
