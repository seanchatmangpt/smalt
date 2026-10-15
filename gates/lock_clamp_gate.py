#!/usr/bin/env python3
"""Invariant gate: lock duration clamp 100..30000 ms.

Positive: for three ARM-configured lock durations ("PT1H" -> 30000 clamp-high,
"PT0S" -> 100 clamp-low, "PT5S" -> 5000 unclamped middle), the gate PUTs a
Service Bus queue with that lockDuration through the ARM gateway on a live
substrate, then drives the raw AMQP listener (gates/amqp_invariant_driver.exs,
mode "lockclamp") to enqueue one message and read x-opt-locked-until off the
delivery. The observed lock delta must match the CLAMPED duration, not the
requested one (Smalt.Amqp.LockManager.clamp_duration via
Smalt.Amqp.QueueStore.queue_settings).

Negative fixtures: mutated deltas (unclamped high, zero, unclamped low,
crossed bounds) must each be refused.

Usage: python3 gates/lock_clamp_gate.py   (exit 0 = hold, 1 = violated)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

NS = "gate-ns"
API_VERSION = "2021-04-01"  # ServiceBus surface rejects 2021-01-01
CASES = [
    # (ARM lockDuration, requested ms, expected clamped ms)
    ("PT1H", 3_600_000, 30_000),
    ("PT0S", 0, 100),
    ("PT5S", 5_000, 5_000),
]
TOLERANCE_MS = 2_000


def capture(ports, shared_key):
    arm = ports["arm"]
    queue_specs = []
    ns_path = (f"/subscriptions/gates-sub/resourceGroups/gates-rg/providers/"
               f"Microsoft.ServiceBus/namespaces/{NS}?api-version={API_VERSION}")
    s_ns, _, ns_body = common.http(arm, "PUT", ns_path, {"location": "gates", "skuName": "Standard"})
    assert s_ns in (200, 201), f"ARM namespace PUT returned {s_ns}: {ns_body}"
    for duration, requested, expected in CASES:
        name = f"gate-lock-{expected}"
        path = (f"/subscriptions/gates-sub/resourceGroups/gates-rg/providers/"
                f"Microsoft.ServiceBus/namespaces/{NS}/queues/{name}"
                f"?api-version={API_VERSION}")
        s, _, body = common.http(arm, "PUT", path,
                                 {"location": "gates",
                                  "properties": {"lockDuration": duration}})
        assert s in (200, 201), f"ARM queue PUT {name} returned {s}: {body}"
        queue_specs.append(f"{name}:{expected}")

    result = common.run_amqp_driver(
        "lockclamp",
        {"SMALT_AMQP_PORT": ports["amqp"], "SMALT_LOCK_QUEUES": ",".join(queue_specs),
         "SMALT_SB_SHARED_KEY": shared_key})

    obs = {"requested": {}, "observed_delta": {}}
    for duration, requested, expected in CASES:
        obs["requested"][str(expected)] = requested
    for o in result.get("observations", []):
        obs["observed_delta"][str(o["queue"].rsplit("-", 1)[-1])] = {
            "delta": o.get("delta_ms"),
            "delivery_count": o.get("delivery_count"),
        }
    return obs


def verdict(obs):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    deltas = obs.get("observed_delta", {})
    check(len(deltas) == len(CASES),
          f"one delivery observed per queue (got {len(deltas)})")
    for duration, requested, expected in CASES:
        entry = deltas.get(str(expected))
        delta = entry.get("delta") if entry else None
        check(isinstance(delta, int),
              f"lockDuration {duration}: locked-until observed")
        if isinstance(delta, int):
            # floor: the observed delta must be AT the clamped value (within
            # scheduling slop of 100ms below, 2000ms above) — a delta of 0 or a
            # raw unclamped value must refuse. Same-host clock, so the delta
            # can never legitimately undershoot by more than encode latency.
            lo, hi = max(expected - 100, expected // 2), expected + TOLERANCE_MS
            check(lo <= delta <= hi,
                  f"lockDuration {duration} ({requested}ms): lock delta {delta}ms "
                  f"within clamped [{lo},{hi}]ms")
    return ok, details


def mutate_fixtures(obs):
    import copy

    def unclamped_high(o):
        o = copy.deepcopy(o)
        o["observed_delta"]["30000"]["delta"] = 3_600_000
        return o

    def zero_delta(o):
        o = copy.deepcopy(o)
        o["observed_delta"]["100"]["delta"] = 0
        return o

    def unclamped_low(o):
        o = copy.deepcopy(o)
        o["observed_delta"]["5000"]["delta"] = 0
        return o

    def missing_delivery(o):
        o = copy.deepcopy(o)
        o["observed_delta"] = {}
        return o

    return [(n, f(obs)) for n, f in
            [("unclamped-high", unclamped_high),
             ("zero-delta", zero_delta),
             ("unclamped-low", unclamped_low),
             ("missing-delivery", missing_delivery)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("lock-clamp", capture, verdict, mutate_fixtures))
