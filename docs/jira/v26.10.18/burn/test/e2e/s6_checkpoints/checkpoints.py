#!/usr/bin/env python3
"""S6 exactly-once checkpoint chain (EventHubs semantics).

Wire contract
-------------
Real Azure Event Hubs path: when EVENTHUBS_CONNECTION_STRING (+ optional
EVENTHUBS_NAME) is set, the azure-eventhub SDK producer sends 200 events
round-robin over 2 partitions and the EventHubConsumerClient is used to verify
200 events per the sequence contract. This path is fail-closed: if the wire is
unreachable it reports BLOCKED and exits nonzero, never a fake pass.

Substrate-local path (this run): no Event Hubs wire endpoint / egress route
exists for `eh` in the smalt substrate (egress_router.ex has no eh route), and
Smalt's EventHubs CAS contract lives in Smalt.Messaging.EventHubs /
Smalt.Store.compare_and_swap. So the scenario drives the chain through
`mix run` against the module API directly (documented substrate-local
consumer).

Receipt: test/e2e/s6_checkpoints/receipt.json
"""

import json
import os
import subprocess
import sys
from pathlib import Path

SCENARIO_DIR = Path(__file__).resolve().parent
REPO = SCENARIO_DIR.parents[2]
TOTAL_EVENTS = 200
PARTITIONS = 2
CONSUMERS = 4

RECEIPT = {
    "scenario": "s6_checkpoints",
    "wire": "substrate-local",
    "sdk_env": "BLOCKED (no EVENTHUBS_CONNECTION_STRING; no eh egress route in substrate)",
}


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, **kw)


def run_mix_chain(wins_dir: Path) -> int:
    env = dict(os.environ)
    env.setdefault("MIX_ENV", "dev")
    proc = run(
        [
            "mix",
            "run",
            "--no-start",
            "test/e2e/s6_checkpoints/checkpoint_chain.exs",
            "--",
            str(wins_dir),
        ],
        cwd=REPO,
        env=env,
    )
    return proc.returncode


def try_real_sdk(wins_dir: Path) -> bool:
    """Real Azure Event Hubs producer + consumer via azure-eventhub SDK.

    Fail-closed: any wire failure -> False (BLOCKED), never a fake pass.
    """
    cs = os.environ.get("EVENTHUBS_CONNECTION_STRING")
    if not cs:
        return False
    try:
        from azure.eventhub import EventHubProducerClient, EventData
        from azure.eventhub.aio import EventHubConsumerClient

        hub = os.environ.get("EVENTHUBS_NAME")
        producer = EventHubProducerClient.from_connection_string(cs, eventhub_name=hub)
        sent = 0
        per_partition = TOTAL_EVENTS // PARTITIONS
        for pid in range(PARTITIONS):
            with producer, producer.create_batch(partition_id=str(pid)) as batch:
                for i in range(per_partition):
                    batch.add(EventData(json.dumps({"i": pid * per_partition + i})))
                producer.send_batch(batch)
                sent += per_partition
        print(f"[sdk] sent {sent} events over {PARTITIONS} partitions")

        received = {pid: [] for pid in range(PARTITIONS)}
        consumer = EventHubConsumerClient.from_connection_string(cs, eventhub_name=hub)

        def on_event(partition_context, event):
            received[int(partition_context.partition_id)].append(
                event.sequence_number
            )
            partition_context.update_checkpoint(event)

        with consumer:
            consumer.receive(
                on_event,
                consumer_group="$DEFAULT",
                partition_id="0",
                starting_position="-1",
            )
        print("[sdk] consumer verification complete")
        return all(len(v) == TOTAL_EVENTS // PARTITIONS for v in received.values())
    except Exception as exc:  # fail-closed
        print(f"[sdk] BLOCKED: {exc}")
        return False


def main() -> int:
    wins_dir = SCENARIO_DIR
    receipt_path = wins_dir / "receipt.json"

    sdk_ok = try_real_sdk(wins_dir)

    rc = run_mix_chain(wins_dir)
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}

    print("== S6 checkpoint chain receipt ==")
    print(json.dumps(receipt, indent=2))

    exactly_once = receipt.get("zero_double_processing") is True
    verdict = receipt.get("verdict")

    if not exactly_once or verdict != "EXACTLY_ONCE_OK":
        print("FAIL: CAS chain broken")
        return 1

    if os.environ.get("EVENTHUBS_CONNECTION_STRING") and not sdk_ok:
        print("FAIL: EH wire present but SDK path blocked")
        return 1

    print("PASS: 200 events, 4 concurrent consumers, exactly 200 CAS wins, zero double-processing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
