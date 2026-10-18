#!/usr/bin/env python3
"""Validate an OCEL 2.0 JSON document.

Enforces:
  1. Top-level OCEL 2.0 keys: ocel:globalLog, ocel:eventTypes, ocel:objectTypes, ocel:events, ocel:objects
  2. Complete referential integrity: every relationship objectId points to an existing object.
  3. Non-empty object and event counts.
  4. Typed events match ocel:eventTypes.
  5. Typed objects match ocel:objectTypes.

Usage: python3 scripts/validate_ocel2.py file1.ocel.json [file2.ocel.json ...]
Exit: 0 on valid, 1 on invalid.
"""

import json
import os
import sys

REQUIRED_TOP_KEYS = [
    "ocel:globalLog",
    "ocel:eventTypes",
    "ocel:objectTypes",
    "ocel:events",
    "ocel:objects"
]

def validate_ocel2_file(path):
    if not os.path.exists(path):
        print(f"[OCEL2-VAL] FAIL: File not found: {path}", file=sys.stderr)
        return False

    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except Exception as e:
        print(f"[OCEL2-VAL] FAIL: Invalid JSON in {path}: {e}", file=sys.stderr)
        return False

    # 1. Top-level keys
    for k in REQUIRED_TOP_KEYS:
        if k not in doc:
            print(f"[OCEL2-VAL] FAIL {path}: Missing required top-level key '{k}'", file=sys.stderr)
            return False

    events = doc["ocel:events"]
    objects = doc["ocel:objects"]
    event_types = set(doc["ocel:eventTypes"])
    object_types = set(doc["ocel:objectTypes"])

    if not isinstance(events, list) or not isinstance(objects, list):
        print(f"[OCEL2-VAL] FAIL {path}: ocel:events and ocel:objects must be lists", file=sys.stderr)
        return False

    if len(events) == 0:
        print(f"[OCEL2-VAL] FAIL {path}: ocel:events list is empty", file=sys.stderr)
        return False

    if len(objects) == 0:
        print(f"[OCEL2-VAL] FAIL {path}: ocel:objects list is empty", file=sys.stderr)
        return False

    # 2. Objects index & type check
    obj_ids = set()
    for o in objects:
        oid = o.get("id")
        otype = o.get("type")
        if not oid or not isinstance(oid, str):
            print(f"[OCEL2-VAL] FAIL {path}: Object missing valid 'id': {o}", file=sys.stderr)
            return False
        if not otype or otype not in object_types:
            print(f"[OCEL2-VAL] FAIL {path}: Object '{oid}' has undeclared type '{otype}'", file=sys.stderr)
            return False
        obj_ids.add(oid)

    # 3. Events & referential integrity
    for ev in events:
        eid = ev.get("id")
        etype = ev.get("type")
        if not eid or not isinstance(eid, str):
            print(f"[OCEL2-VAL] FAIL {path}: Event missing valid 'id': {ev}", file=sys.stderr)
            return False
        if not etype or etype not in event_types:
            print(f"[OCEL2-VAL] FAIL {path}: Event '{eid}' has undeclared type '{etype}'", file=sys.stderr)
            return False

        rels = ev.get("relationships", [])
        if not isinstance(rels, list):
            print(f"[OCEL2-VAL] FAIL {path}: Event '{eid}' relationships must be list", file=sys.stderr)
            return False

        for r in rels:
            target = r.get("objectId")
            if target not in obj_ids:
                print(f"[OCEL2-VAL] FAIL {path}: Dangling relationship in event '{eid}' -> target '{target}' not found in objects", file=sys.stderr)
                return False

    print(f"[OCEL2-VAL] PASS {path}: {len(events)} events, {len(objects)} objects, referential integrity OK")
    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/validate_ocel2.py <file1.ocel.json> ...", file=sys.stderr)
        sys.exit(1)

    all_ok = True
    for p in sys.argv[1:]:
        if not validate_ocel2_file(p):
            all_ok = False

    sys.exit(0 if all_ok else 1)

if __name__ == "__main__":
    main()
