#!/usr/bin/env python3
# Lens-4 cycle-4: SECOND independent JCS-subset implementation (anti-oracle-
# monoculture). Node/V8 was oracle #1; this is CPython's json module + a
# hand-rolled UTF-16-code-unit sort — an entirely different serializer.
# Floats are excluded from the comparable set (Python float repr differs from
# ECMAScript Number::toString; numbers are already cross-witnessed by
# tp_numedge vs node).
import json, sys

FLOAT = "\x00FLOAT\x00"

def jcs(v):
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return FLOAT
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(jcs(x) for x in v) + "]"
    if isinstance(v, dict):
        items = sorted(v.items(), key=lambda kv: kv[0].encode("utf-16-be"))
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + jcs(val) for k, val in items) + "}"
    return FLOAT

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    print(jcs(json.loads(line)))
