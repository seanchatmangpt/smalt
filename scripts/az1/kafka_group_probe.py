#!/usr/bin/env python3
"""KD-190 layer-2 court probe: real kafka-python-ng consumer-group flow
against the smalt Kafka group face.

Legs (exit 0 = all pass, nonzero = loud fail):
  A  subscribe -> poll -> receive -> commit -> close (LeaveGroup served)
  B  new consumer, same group: resumes from leg A's committed offsets
  C  two consumers, same group: disjoint roundrobin assignment over the
     2-partition "kafka" topic

No mocks, no fixed sleeps: every wait is a bounded poll on a real
observable (consumer.poll / assignment / committed) with a hard deadline.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.environ.get("KAFKALIB", "tmp/kafkalib"))

import logging  # noqa: E402

logging.basicConfig(level=logging.DEBUG)
from kafka import KafkaConsumer, KafkaProducer  # noqa: E402
from kafka.structs import TopicPartition  # noqa: E402

TOPIC = "kafka"
_LEG_A_SEEN = set()


def produce_seed(port, tag, per_partition=2):
    prod = KafkaProducer(
        bootstrap_servers=[f"127.0.0.1:{port}"],
        api_version=(0, 11, 0),
        linger_ms=0,
        retries=0,
    )
    sent = {}
    for p in (0, 1):
        vals = [f"{tag}-p{p}-{i}".encode() for i in range(per_partition)]
        for v in vals:
            prod.send(TOPIC, value=v, partition=p).get(timeout=15)
        sent[p] = vals
    prod.flush(timeout=15)
    # probe posture: api_version=(0,10,1) pinned for the producer's client check
    prod.close(timeout=15)
    return sent


def bounded(poll_fn, deadline_s=40):
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        out = poll_fn()
        if out:
            return out
    raise AssertionError("bounded wait exhausted")


def consumer(port, group, **kw):
    return KafkaConsumer(
        bootstrap_servers=[f"127.0.0.1:{port}"],
        group_id=group,
        api_version=(0, 10, 1),
        auto_offset_reset="earliest",
        enable_auto_commit=False,
        session_timeout_ms=60000,
        heartbeat_interval_ms=3000,
        **kw,
    )


def poll_records(c, deadline_s=40):
    acc = []

    def step():
        batch = c.poll(timeout_ms=1000)
        for _tp, recs in batch.items():
            acc.extend(recs)
        return acc

    return bounded(step, deadline_s)


def leg_a(port, group, tag):
    c = consumer(port, group)
    c.subscribe([TOPIC])
    recs = poll_records(c)
    _LEG_A_SEEN.update((r.partition, r.offset) for r in recs)
    c.commit()
    # NOTE: kafka-python caches committed offsets client-side (committed()
    # does not re-fetch from the wire), so the commit is witnessed by the
    # leg-B resume, not by committed().
    committed = {}
    for r in recs:
        committed[r.partition] = max(committed.get(r.partition, 0), r.offset + 1)
    c.close()
    return recs, committed


def leg_b(port, group, expected_commit, tag):
    c = consumer(port, group)
    c.subscribe([TOPIC])
    # resume witness: the new consumer must NOT re-receive committed records;
    # wait (bounded) for the assignment, then positions must equal the commit
    def step():
        c.poll(timeout_ms=500)
        a = c.assignment()
        if not a:
            return None
        return a

    a = bounded(step, 40)
    assert a, "no assignment"
    end = time.monotonic() + 3
    while time.monotonic() < end:
        batch = c.poll(timeout_ms=500)
        for _tp, recs in batch.items():
            for r in recs:
                assert (r.partition, r.offset) not in _LEG_A_SEEN, \
                    f"resume leg re-received committed record p{r.partition}@{r.offset}"
    pos = {tp.partition: c.position(tp) for tp in a}
    for p_, off in expected_commit.items():
        assert pos[p_] == off, f"position p{p_}={pos[p_]} != committed {off}"
    c.close()
    print("PASS legB resume-from-commit pos=%s" % (pos,))
    return True


def leg_c(port, group, tag):
    import threading

    c1 = consumer(port, group)
    c2 = consumer(port, group)
    c1.subscribe([TOPIC])
    c2.subscribe([TOPIC])

    stop = threading.Event()
    res = {}

    def spin(name, c):
        got = []
        while not stop.is_set():
            batch = c.poll(timeout_ms=500)
            for _tp, recs in batch.items():
                got.extend(recs)
        res[name] = (got, c)

    t1 = threading.Thread(target=spin, args=("c1", c1))
    t2 = threading.Thread(target=spin, args=("c2", c2))
    t1.start()
    t2.start()
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        time.sleep(0.5)
        a1 = {tp.partition for tp in c1.assignment()}
        a2 = {tp.partition for tp in c2.assignment()}
        if a1 and a2 and not (a1 & a2) and (a1 | a2) == {0, 1}:
            break
    stop.set()
    t1.join(timeout=5)
    t2.join(timeout=5)
    assert a1 and a2 and not (a1 & a2) and (a1 | a2) == {0, 1}, \
        f"pair assignment never converged: a1={a1} a2={a2}"
    print("PASS legC disjoint roundrobin a1=%s a2=%s" % (a1, a2))
    c1.close()
    c2.close()
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--tag", required=True, help="unique tag for this run")
    args = ap.parse_args()
    port = args.port
    tag = args.tag

    produce_seed(port, tag)
    print("PASS produce seed")

    ga = f"{tag}-resume"
    recs, committed = leg_a(port, ga, tag)
    assert recs, "leg A received nothing"
    assert committed and all(v is not None and v >= 1 for v in committed.values()), \
        f"commit leg got {committed}"
    print("PASS legA commit %s" % (committed,))

    leg_b(port, ga, committed, tag)
    print("PASS legB resume-from-commit")

    leg_c(port, f"{tag}-pair", tag)
    print("PASS ALL")
    return 0


if __name__ == "__main__":
    import traceback

    try:
        rc = main()
        sys.stdout.flush()
        os._exit(rc)  # kafka-python background threads cannot join at interpreter shutdown
    except BaseException:
        traceback.print_exc()
        sys.stdout.flush()
        os._exit(1)
