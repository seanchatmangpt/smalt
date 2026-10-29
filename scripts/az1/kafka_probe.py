#!/usr/bin/env python3
"""AZ-1 court probe: real Kafka wire client (kafka-python-ng).

TEST-ONLY dep lives in tmp/kafkalib (never lib/). Exit 0 = PASS, nonzero
= FAIL (loud, never a fake pass).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.environ.get("KAFKALIB", "tmp/kafkalib"))

from kafka import KafkaProducer, KafkaConsumer  # noqa: E402
from kafka.structs import TopicPartition  # noqa: E402

TOPIC = "kafka"


def produce(port, values):
    producer = KafkaProducer(
        bootstrap_servers=[f"127.0.0.1:{port}"],
        linger_ms=0,
        retries=0,
    )
    for value in values:
        future = producer.send(TOPIC, value.encode("utf-8"))
        future.get(timeout=15)  # raise on broker refusal (typed, loud)
    producer.flush(timeout=15)
    producer.close(timeout=15)
    print("PRODUCED " + json.dumps(values))
    return 0


def consume(port, values, timeout, filter_prefix=None):
    consumer = KafkaConsumer(
        bootstrap_servers=[f"127.0.0.1:{port}"],
        group_id=None,
        enable_auto_commit=False,
        consumer_timeout_ms=timeout * 1000,
    )
    tp0 = TopicPartition(TOPIC, 0)
    tp1 = TopicPartition(TOPIC, 1)
    consumer.assign([tp0, tp1])
    consumer.seek_to_beginning(tp0, tp1)
    got = []
    for msg in consumer:
        got.append(msg.value)
    consumer.close()
    got_s = sorted(v.decode("utf-8", "replace") for v in got)
    if filter_prefix:
        got_s = [v for v in got_s if v.startswith(filter_prefix)]
    want_s = sorted(values)
    if got_s != want_s:
        print("FAIL consume mismatch")
        print("GOT " + json.dumps(got_s))
        return 1
    print("PASS consume byte-exact n=" + str(len(values)))
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=["produce", "consume"], required=True)
    parser.add_argument("--values", default="")
    parser.add_argument("--filter-prefix", default=None,
                        help="compare only consumed values with this prefix "
                             "(test-order isolation: earlier tests' messages "
                             "stay in the shared per-run journal)")
    args = parser.parse_args()
    values = [v for v in args.values.split(",") if v]
    if args.mode == "produce":
        return produce(args.port, values)
    return consume(args.port, values, 20, args.filter_prefix)


if __name__ == "__main__":
    sys.exit(main())
