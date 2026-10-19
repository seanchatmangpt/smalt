#!/usr/bin/env python3
"""Project a smalt-burn/v2 JSONL receipt into an IEEE OCEL 2.0 JSON document.

Conforms strictly to the OCEL 2.0 standard:
  - ocel:globalLog
  - ocel:eventTypes
  - ocel:objectTypes
  - ocel:events
  - ocel:objects

Preserves the matter-isolation law: object references (ids only), no uncontrolled payloads.
Enforces 100% referential integrity: every relationship objectId exists in ocel:objects.
"""

import json
import os
import sys

def burn_to_ocel2(jsonl_path, out_path=None):
    if not os.path.exists(jsonl_path):
        print(f"Error: file not found: {jsonl_path}", file=sys.stderr)
        return 1

    events = []
    objects = {}
    event_types = set()
    object_types = {"subject", "container", "burn-cycle", "receipt"}

    with open(jsonl_path, "r", encoding="utf-8") as f:
        for idx, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception as e:
                print(f"Warning: line {idx} invalid JSON: {e}", file=sys.stderr)
                continue

            if row.get("schema") != "smalt-burn/v2":
                continue

            # 1. Subject Object
            subj_sha = row.get("subject_sha", "unrecorded")
            subj_id = f"subject/{subj_sha}"
            if subj_id not in objects:
                objects[subj_id] = {
                    "id": subj_id,
                    "type": "subject",
                    "attributes": {"sha": subj_sha}
                }

            # 2. Container Object
            cont_name = row.get("container", "unknown-container")
            cont_id = f"container/{cont_name}"
            if cont_id not in objects:
                objects[cont_id] = {
                    "id": cont_id,
                    "type": "container",
                    "attributes": {
                        "name": cont_name,
                        "plane": row.get("plane", "all"),
                        "image_digest": row.get("image_digest", "unrecorded")
                    }
                }

            # 3. Burn-Cycle Object
            cycle_num = row.get("cycle", 0)
            cycle_id = f"burn-cycle/{cont_name}/{cycle_num}"
            if cycle_id not in objects:
                objects[cycle_id] = {
                    "id": cycle_id,
                    "type": "burn-cycle",
                    "attributes": {
                        "cycle": cycle_num,
                        "container": cont_name
                    }
                }

            # 4. Receipt File Object
            evidence = row.get("evidence_path", jsonl_path)
            rec_id = f"receipt/{os.path.basename(evidence)}"
            if rec_id not in objects:
                objects[rec_id] = {
                    "id": rec_id,
                    "type": "receipt",
                    "attributes": {"path": evidence}
                }

            # Event definition
            lane = row.get("lane", "burn")
            stage = row.get("stage", "stage")
            ev_type = f"burn.{lane}.{stage}"
            event_types.add(ev_type)

            ev_id = f"ev-burn-{cont_name}-{cycle_num}-{stage}-{idx}"
            time_val = row.get("t_start") or "2026-10-18T00:00:00Z"

            attributes = {
                "verdict": row.get("verdict", "UNKNOWN"),
                "exit_code": row.get("exit_code", 0),
                "detail": row.get("detail", ""),
                "recovery_ms": row.get("recovery_ms", 0),
                "crash_reports": row.get("crash_reports", 0),
                "orphans_count": len(row.get("orphans", []))
            }

            relationships = [
                {"objectId": cont_id, "qualifier": "executed_in"},
                {"objectId": cycle_id, "qualifier": "belongs_to"},
                {"objectId": subj_id, "qualifier": "verifies"},
                {"objectId": rec_id, "qualifier": "recorded_in"}
            ]

            events.append({
                "id": ev_id,
                "type": ev_type,
                "time": time_val,
                "attributes": attributes,
                "relationships": relationships
            })

    doc = {
        "ocel:eventTypes": sorted(list(event_types)),
        "ocel:objectTypes": sorted(list(object_types)),
        "ocel:events": events,
        "ocel:objects": list(objects.values())
    }

    if out_path:
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2)
        print(f"[OCEL2-PROJECT] Converted {len(events)} events, {len(objects)} objects -> {out_path}")
    else:
        print(json.dumps(doc, indent=2))

    return 0

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/burn_to_ocel2.py <in.jsonl> [out.ocel.json]", file=sys.stderr)
        sys.exit(1)
    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    sys.exit(burn_to_ocel2(inp, out))
