#!/usr/bin/env python3
"""HAVE component 8 — RP-04 formal conformance: OCEL 2.0 log replayed against a
Petri net of the canonical settlement lifecycle.

Lifecycle (RP-04):
    arm.resource.transition -> amqp.delivery.settled -> blob.custody.transition

Net encoding: a JSON transition table; each transition names its input places
(consumed tokens) and output places (produced tokens). Events are replayed in
`time` order; each event of a net-known type consumes one token from every
input place and produces one into every output place. Per place we compute
Tokens_produced and Tokens_consumed; drift = produced - consumed - final
marking declared by the net. Any place with drift != 0 emits a typed
ALRT-SEV1-PETRI-TOKEN-IMBALANCE row naming the exact broken lifecycle link.

Classification of an imbalance:
  - REGRESSION: the failing event type IS declared in the net (an existing
    lifecycle link broke — e.g. amqp.delivery.settled never fired between
    arm and blob transitions) -> quarantine the build.
  - PROTOCOL-UPDATE: the OCEL log carries an event type the net does not
    declare (the process changed and the net must be re-pinned) -> mint a
    decision record (ADR) under docs/jira/v26.10.18/decisions/.

OCEL 2.0 input shape (as emitted by scripts/burn_to_ocel2.py):
    {"ocel:eventTypes": [...], "ocel:objectTypes": [...],
     "ocel:events": [{"id","type","time","attributes","relationships"}...],
     "ocel:objects": [...]}

CLI:
    python3 scripts/have/petri_conformance.py <log.ocel.json> [options]
      --net PATH        transition table (default: scripts/have/petri_net.json)
      --quarantine      on REGRESSION, write tmp/have/QUARANTINE (exit 1)
      --mint-adr        on PROTOCOL-UPDATE, write an ADR under docs decisions/
      --quiet           suppress human rows, exit code is the verdict

Exit codes: 0 conformant, 1 imbalance/regression, 2 usage/IO error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_NET = os.path.join(REPO_ROOT, "scripts", "have", "petri_net.json")
DECISIONS_DIR = os.path.join(REPO_ROOT, "docs", "jira", "v26.10.18", "decisions")
QUARANTINE_PATH = os.path.join("tmp", "have", "QUARANTINE")
ALERT_TYPE = "ALRT-SEV1-PETRI-TOKEN-IMBALANCE"


def _p(*parts: str) -> str:
    return os.path.join(REPO_ROOT, *parts)


# ---------------------------------------------------------------- net loading

def load_net(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        net = json.load(f)
    required = {"name", "places", "transitions"}
    missing = required - set(net)
    if missing:
        raise ValueError(f"net {path}: missing keys {sorted(missing)}")
    for tname, t in net["transitions"].items():
        for key in ("input", "output"):
            if not isinstance(t.get(key), list):
                raise ValueError(f"transition {tname}: '{key}' must be a list of places")
    return net


def load_ocel(path: str) -> dict:
    with open(path, "real utf-8".replace("real ", ""), encoding="utf-8") as f:
        doc = json.load(f)
    for key in ("ocel:events", "ocel:eventTypes", "ocel:objects"):
        if key not in doc:
            raise ValueError(f"OCEL doc missing {key!r}")
    return doc


def _final_marking(net: sound_net) -> dict:
    pass
