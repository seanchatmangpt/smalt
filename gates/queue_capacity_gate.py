#!/usr/bin/env python3
"""Invariant gate: queue capacity 4096 — the 4097th message is refused.

Positive: boot the substrate on private ports, then drive the raw AMQP
listener (gates/amqp_invariant_driver.exs, mode "capacity"): fill a fresh
queue with 4096 settled transfers, send a 4097th, and require the broker to
close with amqp:link-message-size-exceeded and ":capacity" in the description
(lib/smalt/messaging/amqp/connection.ex: QueueStore.enqueue {:error,:capacity}).

Negative fixtures: mutated close-frame observations (accepted 4097th, wrong
condition, missing description, socket drop without a ruled refusal) must each
be refused.

Usage: python3 gates/queue_capacity_gate.py   (exit 0 = hold, 1 = violated)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

QUEUE = "gate-capq"


def capture(ports, shared_key):
    result = common.run_amqp_driver(
        "capacity", {"SMALT_AMQP_PORT": ports["amqp"], "SMALT_CAP_QUEUE": QUEUE,
                     "SMALT_SB_SHARED_KEY": shared_key})
    return {
        "condition": result.get("result", {}).get("condition"),
        "description": result.get("result", {}).get("description"),
    }


def verdict(obs):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    condition = obs.get("condition")
    description = obs.get("description") or ""
    check(condition == "amqp:link-message-size-exceeded",
          f"broker closes with amqp:link-message-size-exceeded (got {condition})")
    check("capacity" in description,
          f"close description names :capacity (got {description!r})")
    return ok, details


def mutate_fixtures(obs):
    def overfill_accepted(o):
        o = dict(o)
        o["condition"] = None
        o["description"] = ""
        return o

    def wrong_condition(o):
        o = dict(o)
        o["condition"] = "amqp:internal-error"
        return o

    def silent_socket_drop(o):
        o = dict(o)
        o["condition"] = "socket-closed"
        o["description"] = "no close frame"
        return o

    return [(n, f(obs)) for n, f in
            [("overfill-accepted", overfill_accepted),
             ("wrong-condition", wrong_condition),
             ("silent-socket-drop", silent_socket_drop)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("queue-capacity", capture, verdict, mutate_fixtures))
