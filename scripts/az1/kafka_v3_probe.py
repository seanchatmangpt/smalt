#!/usr/bin/env python3
"""KD-174 layer-1 court probe: real kafka-python-ng client negotiating
Produce v3 (magic-2 RecordBatch) against the smalt Kafka face.

Witnesses the ApiVersions matrix (Produce advertised 0..3), then pins
api_version=(0,11,0) — the KD-174D2 probe posture — and produces; the
produce leg rides Produce v3 / magic-2 RecordBatches.

Exit 0 = PASS, nonzero = FAIL (loud, never a fake pass). No mocks, no sleeps.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.environ.get("KAFKALIB", "tmp/kafkalib"))

from kafka import KafkaClient, KafkaProducer  # noqa: E402
from kafka.protocol.produce import ProduceRequest  # noqa: E402

TOPIC = "kafka"


def main():
    ap = argparse.ArgumentParser()
    av = None
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--values", required=True, help="comma-separated values")
    args = ap.parse_args()

    client = KafkaClient(bootstrap_servers=[f"127.0.0.1:{args.port}"])
    client.check_version()

    api_versions = getattr(client, "_api_versions", None) or {}
    produce_range = api_versions.get(ProduceRequest[0].API_KEY)
    print("NEGOTIATED-PRODUCE %s" % (produce_range,))

    if not produce_range or produce_range[1] < 3:
        print("FAIL produce not advertised at v3: %s" % (produce_range,))
        return 1

    producer = KafkaProducer(
        bootstrap_servers=[f"127.0.0.1:{args.port}"],
        api_version=(0, 11, 0),
        linger_ms=0,
        retries=0,
    )
    values = args.values.split(",")
    for value in values:
        producer.send(TOPIC, value.encode("utf-8")).get(timeout=15)
    producer.flush(timeout=15)
    producer.close(timeout=15)
    print("PRODUCED " + json.dumps(values))
    return 0


if __name__ == "__main__":
    sys.exit(main())
