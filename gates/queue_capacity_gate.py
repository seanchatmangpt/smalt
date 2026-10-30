#!/usr/bin/env python3
"""Invariant gate: queue capacity 4096 — the 4097th message is refused.

WO-22/23/24 retarget note (v26.10.31 inversion, L8 split): the AMQP
link-detach refusal (amqp:link:message-size-exceeded, connection
survives) is the CORE half and stays here. The ARM LRO
entity-materialization prologue below (namespace/queue PUT + poll) is
the DIALECT half — DIALECT-PENDING until posh/internal/dialect/azure/
exists; it currently runs against the core ARM face and must migrate
to a dialect contract fixture when the dialect package lands.

Positive: boot the substrate on private ports, PUT the queue through the ARM
gateway (KD-86: auto-ensure is OFF by default — a send to a never-created
entity is refused, so the gate must materialize the entity like a real
client), then drive the raw AMQP listener (gates/amqp_invariant_driver.exs,
mode "capacity"): fill a fresh queue with 4096 settled transfers, send a
4097th, and require the broker to detach the SENDER LINK with
amqp:link:message-size-exceeded and ":capacity" in the description while the
CONNECTION SURVIVES (spec §2.8.15; lib/smalt/messaging/amqp/connection.ex
{:error, :capacity} link-detach clause).

Negative fixtures: mutated ruling observations (accepted 4097th, wrong
condition, missing description, socket drop without a ruled refusal) must each
be refused.

Usage: python3 gates/queue_capacity_gate.py   (exit 0 = hold, 1 = violated)
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

QUEUE = "gate-capq"
NS = "gate-ns"
API_VERSION = "2021-04-01"


def capture(ports, shared_key):
    # Materialize the entity through the ARM gateway (premise-rot fix: KD-86
    # means an un-created queue refuses sends with MessagingEntityNotFound —
    # the old gate ran its whole 4096-transfer fill against a missing queue,
    # the sender link got amqp:not-found-detached, and the fill flood then
    # error-closed the connection on "transfer on unknown handle").
    arm = ports["arm"]
    ns_path = (f"/subscriptions/gates-sub/resourceGroups/gates-rg/providers/"
               f"Microsoft.ServiceBus/namespaces/{NS}?api-version={API_VERSION}")
    s_ns, _, ns_body = common.http(arm, "PUT", ns_path, {"location": "gates", "skuName": "Standard"})
    if s_ns == 202:
        op_path = ns_body.get("id") if isinstance(ns_body, dict) else None
        assert op_path, f"ARM namespace PUT returned 202 without an operation id: {ns_body}"
        for _ in range(60):
            s_op, _, op_body = common.http(arm, "GET", op_path, None)
            assert s_op == 200, f"LRO poll returned {s_op}: {op_body}"
            if isinstance(op_body, dict) and op_body.get("status") == "Succeeded":
                break
            time.sleep(0.5)  # SLEEP-CLASS: POLL-STEP
        else:
            raise AssertionError(f"ARM namespace LRO did not reach Succeeded: {op_body}")
    else:
        assert s_ns in (200, 201), f"ARM namespace PUT returned {s_ns}: {ns_body}"
    q_path = (f"/subscriptions/gates-sub/resourceGroups/gates-rg/providers/"
              f"Microsoft.ServiceBus/namespaces/{NS}/queues/{QUEUE}"
              f"?api-version={API_VERSION}")
    s_q, _, q_body = common.http(arm, "PUT", q_path, {"location": "gates", "properties": {}})
    assert s_q in (200, 201), f"ARM queue PUT {QUEUE} returned {s_q}: {q_body}"

    result = common.run_amqp_driver(
        "capacity", {"SMALT_AMQP_PORT": ports["amqp"], "SMALT_CAP_QUEUE": QUEUE,
                     "SMALT_SB_SHARED_KEY": shared_key})
    return {
        "condition": result.get("result", {}).get("condition"),
        "description": result.get("result", {}).get("description"),
        "survived": result.get("result", {}).get("survived"),
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
    check(condition == "amqp:link:message-size-exceeded",
          f"broker detaches link with amqp:link:message-size-exceeded (got {condition})")
    check("capacity" in description,
          f"detach description names :capacity (got {description!r})")
    check(obs.get("survived") is True,
          f"connection survives the link detach (got {obs.get('survived')})")
    return ok, details


def mutate_fixtures(obs):
    def overfill_accepted(o):
        o = dict(o)
        o["condition"] = None
        o["description"] = ""
        o["survived"] = True
        return o

    def wrong_condition(o):
        o = dict(o)
        o["condition"] = "amqp:internal-error"
        return o

    def silent_socket_drop(o):
        o = dict(o)
        o["condition"] = "socket-closed"
        o["description"] = "no close frame"
        o["survived"] = False
        return o

    def connection_killed(o):
        # The OLD (divergent) face: detach-with-error but the socket died
        # anyway. Must be refused — survival is load-bearing.
        o = dict(o)
        o["survived"] = False
        return o

    return [(n, f(obs)) for n, f in
            [("overfill-accepted", overfill_accepted),
             ("wrong-condition", wrong_condition),
             ("silent-socket-drop", silent_socket_drop),
             ("connection-killed", connection_killed)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("queue-capacity", capture, verdict, mutate_fixtures))
