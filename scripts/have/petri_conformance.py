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
      --quiet           suppress human rows; the exit code is the verdict

Exit codes: 0 conformant, 1 imbalance (regression or protocol-update),
2 usage/IO error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_NET = os.path.join(REPO_ROOT, "scripts", "have", "petri_net.json")
DECISIONS_DIR = os.path.join(REPO_ROOT, "docs", "jira", "v26.10.18", "decisions")
QUARANTINE_DIR = os.path.join(REPO_ROOT, "tmp", "have", "quarantine")
ALERT_TYPE = "ALRT-SEV1-PETRI-TOKEN-IMBALANCE"


# ---------------------------------------------------------------- loading

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
                raise ValueError(
                    f"transition {tname!r}: '{key}' must be a list of places")
    return net


def load_ocel(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    for key in ("ocel:events", "ocel:eventTypes", "ocel:objects"):
        if key not in doc:
            raise ValueError(f"OCEL doc missing {key!r}")
    return doc


# ---------------------------------------------------------------- replay

def replay(net: dict, doc: dict) -> dict:
    """Replay OCEL events (time-ordered) against the net; return a report."""
    transitions = net["transitions"]

    events = sorted(doc["ocel:events"], key=lambda e: (e.get("time", ""), e.get("id", "")))
    known_types = set(transitions)
    log_types = {e.get("type") for e in events}

    # PROTOCOL-UPDATE candidates: event types present in the log, absent from net.
    unknown = sorted(log_types - known_types)

    initial = {p: int(net.get("initial_marking", {}).get(p, 0)) for p in net["places"]}
    marking = dict(initial)
    produced: dict[str, int] = {p: 0 for p in net["places"]}
    consumed: dict[str, int] = {p: 0 for p in net["places"]}
    starved: list[dict] = []   # firing attempts blocked by an empty input place
    fired: list[str] = []

    for ev in events:
        etype = ev.get("type")
        if etype not in known_types:
            continue  # unknown types handled by classification, not replay
        t = transitions[etype]
        ins = t["input"]
        starved_inputs = [p for p in ins if marking.get(p, 0) < 1]
        if starved_inputs:
            starved.append({
                "event": ev.get("id"),
                "type": etype,
                "time": ev.get("time"),
                "missing_input_places": starved_inputs,
            })
            continue
        for p in ins:
            marking[p] -= 1
            consumed[p] += 1
        for p in t["output"]:
            marking[p] += 1
            produced[p] += 1
        fired.append(ev.get("id", ""))

    # Final marking declared by the net (default: all places drain to 0).
    final = {p: int(net.get("final_marking", {}).get(p, 0)) for p in net["places"]}

    imbalances = []
    for p in sorted(net["places"]):
        # drift = initial + produced - consumed - final; 0 means balanced.
        drift = initial[p] + produced[p] - consumed[p] - final[p]
        if drift != 0:
            imbalances.append({
                "place": p,
                "produced": produced[p],
                "consumed": consumed[p],
                "final_declared": final[p],
                "drift": drift,
            })

    return {
        "net": net["name"],
        "events_total": len(events),
        "events_fired": len(fired),
        "events_starved": len(starved),
        "starved": starved,
        "unknown_event_types": unknown,
        "token_balance": {
            p: {"initial": initial[p], "produced": produced[p], "consumed": consumed[p],
                "final_declared": final[p],
                "drift": initial[p] + produced[p] - consumed[p] - final[p]}
            for p in sorted(net["places"])
        },
        "imbalances": imbalances,
        "conformant": not imbalances and not unknown and not starved,
    }


# ---------------------------------------------------------------- classify

def classify(report: dict, net: dict) -> dict:
    """REGRESSION (net-known link broke) vs PROTOCOL-UPDATE (net is stale)."""
    net_types = set(net["transitions"])
    unknown = set(report["unknown_event_types"])
    broken_types = {s["type"] for s in report["starved"]}
    if unknown:
        return {
            "class": "PROTOCOL-UPDATE",
            "reason": ("OCEL log carries event type(s) %s not declared in net %r; "
                       "the settlement lifecycle changed and the net must be re-pinned"
                       % (", ".join(sorted(unknown)), report["net"])),
            "failing_types": sorted(unknown),
        }
    if broken_types:
        for s in report["starved"]:
            s["broken_link"] = _broken_link(net, s)
        return {
            "class": "REGRESSION",
            "reason": ("transition(s) %s starved: an upstream lifecycle link broke"
                       % ", ".join(sorted(broken_types))),
            "failing_types": sorted(broken_types),
        }
    return {"class": "NONE", "reason": "conformant", "failing_types": []}


def _broken_link(net: dict, starved_ev: dict) -> str:
    """Name the exact broken lifecycle link: the transition(s) that should have
    produced the missing token, i.e. transitions whose output contains the
    starved transition's input place."""
    links = []
    for p in starved_ev["missing_input_places"]:
        producers = [t for t, spec in net["transitions"].items()
                     if p in spec["output"]]
        consumers_next = [t for t, spec in net["transitions"].items()
                          if p in spec["input"] and t != starved_ev["type"]]
        links.append(
            "place %r: produced by {%s} -> consumed by {%s}; starved at event %s"
            % (p, "|".join(producers) or "NONE",
               "|".join(consumers_next) or "NONE", starved_ev["event"]))
    return "; ".join(links)


# ---------------------------------------------------------------- actions

def write_quarantine(report: dict, verdict: dict, log_path: str) -> str:
    import datetime
    os.makedirs(QUARANTINE_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    path = os.path.join(QUARANTINE_DIR, "petri_%s.json" % stamp)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"alert": ALERT_TYPE, "classification": verdict["class"],
                   "reason": verdict["reason"], "log": log_path,
                   "report": report}, f, indent=2)
    return path


def mint_adr(verdict: dict, log_path: str) -> str:
    os.makedirs(DECISIONS_DIR, exist_ok=True)
    existing = [f for f in os.listdir(DECISIONS_DIR) if f.startswith("ADR-")]
    n = len(existing) + 1
    path = os.path.join(DECISIONS_DIR, "ADR-%03d-petri-protocol-update.md" % n)
    stamp = __import__("datetime").datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, "w", encoding="utf-8") as f:
        f.write("""# ADR-%03d — Petri protocol update (HAVE component 8)

- **Date**: %s
- **Status**: PROPOSED (minted mechanically by `scripts/have/petri_conformance.py --mint-adr`)
- **Alert**: `%s`
- **Evidence log**: `%s`

## Context

OCEL replay against net `scripts/have/petri_net.json` found event types in the
live log that the pinned settlement lifecycle does not declare:

```
%s
```

%s

## Decision

Re-pin `scripts/have/petri_net.json` to include the observed transition(s),
or extend the lifecycle spec and re-run conformance. The alert does not clear
until replay reports `conformant: true`.

## Consequences

- The net is the ground truth for settlement conformance; every protocol
  change must land as a net edit plus a receipted re-run.
- This ADR is minted only on PROTOCOL-UPDATE; REGRESSION quarantines instead.
""" % (n, stamp, ALERT_TYPE, os.path.relpath(log_path, REPO_ROOT),
       verdict["reason"], "\n".join("- `%s`" % t for t in verdict["failing_types"])))
    return path


def emit_alert_rows(report: dict, verdict: dict) -> list:
    rows = []
    for s in report["starved"]:
        rows.append({
            "type": ALERT_TYPE, "sev": "SEV1", "class": verdict["class"],
            "event": s["event"], "transition": s["type"],
            "missing_input_places": s["missing_input_places"],
            "broken_link": s.get("broken_link", ""),
        })
    for p in report["imbalances"]:
        rows.append({
            "type": ALERT_TYPE, "sev": "SEV1", "class": verdict["class"],
            "place": p["place"], "produced": p["produced"],
            "consumed": p["consumed"], "final_declared": p["final_declared"],
            "drift": p["drift"],
        })
    for t in report["unknown_event_types"]:
        rows.append({
            "type": ALERT_TYPE, "sev": "SEV1", "class": verdict["class"],
            "unknown_event_type": t,
        })
    return rows


# ---------------------------------------------------------------- main

def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", help="OCEL 2.0 JSON log path")
    ap.add_argument("--net", default=DEFAULT_NET)
    ap.add_argument("--quarantine", action="store_true")
    ap.add_argument("--mint-adr", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    try:
        net = load_net(args.net)
        doc = load_ocel(args.log)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 2

    report = replay(net, doc)
    verdict = classify(report, net)
    rows = emit_alert_rows(report, verdict)

    if not args.quiet:
        print("[PETRI] net=%s events=%d fired=%d starved=%d unknown-types=%d"
              % (report["net"], report["events_total"], report["events_fired"],
                 report["events_starved"], len(report["unknown_event_types"])))
        for p, b in report["token_balance"].items():
            print("[PETRI] place %-28s produced=%d consumed=%d final=%d drift=%d"
                  % (p, b["produced"], b["consumed"], b["final_declared"], b["drift"]))
        for r in rows:
            print("[ALERT] %s %s %s" % (r["type"], json.dumps(r), verdict["class"]))
        print("[PETRI] class=%s conformant=%s reason=%s"
              % (verdict["class"], str(report["conformant"]).upper(), verdict["reason"]))

    if report["conformant"]:
        return 0

    if verdict["class"] == "PROTOCOL-UPDATE" and args.mint_adr:
        path = mint_adr(verdict, args.log)
        if not args.quiet:
            print("[PETRI] minted decision record: %s" % path)
    if verdict["class"] == "REGRESSION" and args.quarantine:
        path = write_quarantine(report, verdict, args.log)
        if not args.quiet:
            print("[PETRI] quarantine written: %s" % path)
    return 1


if __name__ == "__main__":
    sys.exit(main())
