#!/usr/bin/env bash
# S6 exactly-once checkpoint chain (EventHubs semantics), end to end.
#   1. real venv + real pip install of azure-eventhub / azure-identity
#   2. real SDK producer/consumer when EVENTHUBS_CONNECTION_STRING is present
#      (fail-closed otherwise)
#   3. substrate-local CAS chain: producer 200 events / 2 partitions,
#      4 concurrent consumers racing Smalt.Messaging.EventHubs.compare_and_swap
# Usage: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --quiet --disable-pip-version-check azure-eventhub azure-identity

exec .venv/bin/python checkpoints.py
