#!/usr/bin/env python3
"""KD-191 SASL positive probe: real kafka-python-ng client over real TCP.

SASL_PLAINTEXT producer roundtrip against a SASL-required listener.
Prints a NEGOTIATED-SASL marker only when a real authenticated session
completed a real produce roundtrip. TEST-ONLY dep in tmp/kafkalib.
Exit 0 = PASS, nonzero = FAIL (loud, never a fake pass).
"""
import argparse
import os
import sys

sys.path.insert(0, os.environ.get("KAFKALIB", "tmp/kafkalib"))

from kafka import KafkaProducer  # noqa: E402

TOPIC = "kafka"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--user", default="dev")
    parser.add_argument("--password", default="dev-secret")
    args = parser.parse_args()

    producer = KafkaProducer(
        bootstrap_servers=[f"127.0.0.1:{args.port}"],
        security_protocol="SASL_PLAINTEXT",
        sasl_mechanism="PLAIN",
        sasl_plain_username=args.user,
        sasl_plain_password=args.password,
        linger_ms=0,
        retries=0,
    )
    value = f"sasl-roundtrip-{os.getpid()}".encode()
    future = producer.send(TOPIC, value)
    future.get(timeout=15)
    producer.flush(timeout=15)
    producer.close(timeout=15)
    print(f"NEGOTIATED-SASL PLAIN produced {value.decode()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
