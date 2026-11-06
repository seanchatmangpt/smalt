#!/usr/bin/env python3
"""Receipt provenance validator (KD-210).

Law (Tier-2): every numeric metric field in a manufacturing receipt must carry
an explicit measurement-provenance binding. Grammar:

    source := "measured(<command>, <iso-timestamp>)"
            | "const(<path:line>)"
            | "unmeasured"

A numeric metric with no binding  -> REFUSED (missing-source).
A const-bound metric under a PASS/ADMITTED/ALIVE verdict -> REFUSED (pinned-constant).
subject_sha == a216b486fe7d312ad982ff66b158c30ae493ec09 -> REFUSED
(hardcoded-fallback provenance, KD-210 known-poison SHA).

Where bindings may live (all accepted):
  1. value form:      "field": {"value": 12.5, "source": "measured(...)"}
  2. sibling form:    "field": 12.5, "field_source": "measured(...)"
  3. sources map:     "sources": {"field": "measured(...)"}

Fields that are structural rather than measured metrics are exempt:
*_count, counts, total_*, exit, exit_code, schema_version, *_sha.
Everything else numeric (int/float, bool excluded) requires a binding.

Exit codes: 0 = ADMITTED, 1 = REFUSED, 2 = self-test failed (vacuous gate).
`--selftest` runs the three non-vacuity legs and exits 1 if any leg refuses
to fire.
"""

import json
import re
import sys

POISON_SHA = "a216b486fe7d312ad982ff66b158c30ae493ec09"

SOURCE_RE = re.compile(
    r"^(measured\(.+,\s*\d{4}-\d{2}-\d{2}T.*Z\)"
    r"|const\([^):]+:[0-9]+\)"
    r"|unmeasured)$"
)

# Structural numeric fields that are not measurements.
STRUCTURAL_RE = re.compile(
    r"^(.*_count|counts?|total_.*|exit(_code)?|schema_version|.*_sha)$"
)

VERDICT_KEYS = ("verdict", "standing", "status", "result")


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _verdict_of(doc):
    def walk(o):
        if isinstance(o, dict):
            for k in VERDICT_KEYS:
                v = o.get(k)
                if isinstance(v, dict) and isinstance(v.get("value"), str):
                    v = v["value"]
                if isinstance(v, str):
                    v = v.lower()
                    if any(t in v for t in ("pass", "admit", "alive", "conformant")):
                        return v
            for v in o.values():
                r = walk(v)
                if r:
                    return r
        elif isinstance(o, list):
            for v in o:
                r = walk(v)
                if r:
                    return r
        return None
    return walk(doc)


def collect_provenance_defects(doc):
    """Return list of (path, reason) for provenance violations."""
    defects = []

    def walk(node, path, structural=False):
        if isinstance(node, dict):
            sources = node.get("sources", {}) if isinstance(node.get("sources"), dict) else {}
            for key, val in node.items():
                if key == "sources":
                    continue
                p = f"{path}.{key}"
                child_structural = structural or key in ("counts", "totals")
                if _is_number(val) and not structural and not STRUCTURAL_RE.match(key):
                    binding = None
                    kind = None
                    if isinstance(val, dict):
                        binding = val.get("source")
                        kind = "value-form"
                    elif f"{key}_source" in node:
                        binding = node[f"{key}_source"]
                        kind = "sibling-form"
                    elif key in sources:
                        binding = sources[key]
                        kind = "sources-map"
                    if binding is None:
                        defects.append((p, "missing-source"))
                    elif not isinstance(binding, str) or not SOURCE_RE.match(binding):
                        binding_s = json.dumps(binding) if not isinstance(binding, str) else binding
                        defects.append((p, f"malformed-source: {binding_s[:120]}"))
                    elif binding.startswith("const(") and _verdict_of(doc):
                        defects.append((p, "pinned-constant under positive verdict"))
                    elif binding == "unmeasured" and _verdict_of(doc):
                        defects.append((p, "unmeasured metric under positive verdict"))
                elif isinstance(val, dict):
                    walk(val, p, child_structural)
                elif isinstance(val, list) and not child_structural:
                    for i, item in enumerate(val):
                        if isinstance(item, (dict,)):
                            walk(item, f"{p}[{i}]")
                        elif _is_number(item) and not STRUCTURAL_RE.match(key):
                            # numeric list items: require the list key itself to be
                            # bound via a sibling `<key>_source` or sources map
                            binding = node.get(f"{key}_source") or sources.get(key)
                            if binding is None:
                                defects.append((f"{p}[i]", "missing-source"))
                            elif not (isinstance(binding, str) and SOURCE_RE.match(binding)):
                                defects.append((f"{p}[i]", f"malformed-source: {binding}"))
                            elif binding.startswith("const(") and _verdict_of(doc):
                                defects.append((f"{p}[i]", "pinned-constant under positive verdict"))
                            elif binding == "unmeasured" and _verdict_of(doc):
                                defects.append((f"{p}[i]", "unmeasured under positive verdict"))
        # no other node types carry metrics

    walk(doc, "$")
    return defects


def validate(path_or_doc):
    """Validate one receipt. Returns (ok, report_lines)."""
    if isinstance(path_or_doc, str):
        try:
            with open(path_or_doc) as f:
                doc = json.load(f)
        except Exception as e:
            return False, [f"PARSE-ERROR: {path_or_doc}: {e}"]
        label = path_or_doc
    else:
        doc = path_or_doc
        label = "<inline>"

    lines = []
    ok = True

    if isinstance(doc, dict) and isinstance(doc.get("identity"), dict):
        sha = doc["identity"].get("subject_sha")
        if sha == POISON_SHA:
            ok = False
            lines.append(
                f"REFUSED (hardcoded-fallback provenance): subject_sha {sha} "
                f"is the KD-210 known-poison SHA"
            )

    defects = collect_provenance_defects(doc)
    verdict = _verdict_of(doc)
    if defects:
        ok = False
        lines.append(f"REFUSED ({label}): {len(defects)} provenance defect(s)")
        for p, reason in defects[:40]:
            lines.append(f"  - {p}: {reason}")
        if len(defects) > 40:
            lines.append(f"  ... {len(defects) - 40} more")
    elif ok:
        lines.append(f"ADMITTED ({label}): verdict={verdict or 'none'}, all numeric metrics carry source bindings")

    return ok, lines


def selftest():
    """Non-vacuity legs. Returns (ok, output_lines). exit 2 semantics handled by caller."""
    import tempfile, os
    lines = ["== selftest: non-vacuity legs =="]
    ok_all = True

    # Leg A: known-bad cgap receipt shape must REFUSE.
    synthetic_bad = {
        "identity": {"subject_sha": POISON_SHA},
        "standing": {"value": "ALIVE"},
        "economic_exhibit": {
            "status_quo_monthly_usd": 422386.0,  # missing source binding -> must REFUSE
        },
        "cells": [{"cell_id": "C01", "ns_per_record": 320.0, "p99_ms": 0.12}],
    }
    ok, out = validate(synthetic_bad)
    fired = not ok
    lines += out[:6]
    lines.append(f"leg A (known-bad cgap shape): {'FIRED' if fired else 'VACUOUS'}")
    ok_all &= fired

    # Leg B: fabricated-but-well-formed metric with no source -> must REFUSE.
    fab = {
        "identity": {"subject_sha": "b" * 40},
        "standing": {"value": "ALIVE"},
        "metrics": {"latency_p99_ms": 1.23},
    }
    ok, out = validate(fab)
    lines += out[:4]
    fired = not ok
    lines.append(f"leg B (missing source on fabricated metric): {'FIRED' if fired else 'VACUOUS'}")
    ok_all &= fired

    # Leg C: lawful receipt with real measured bindings -> must ADMIT.
    lawful = {
        "identity": {"subject_sha": "c" * 40},
        "standing": {"value": "ALIVE"},
        "metrics": {
            "latency_p99_ms": 1.23,
            "latency_p99_ms_source": "measured(hyperfine -N 'bench --p99', 2026-11-05T06:00:00Z)",
        },
        "counts": {"cells_evaluated": 80},
        "exit": 0,
        "sources": {"rows_scanned": 12345},
        "rows_scanned": 12345,
        "rows_scanned_source": "measured(cat data.csv | wc -l, 2026-11-05T06:00:00Z)",
    }
    ok, out = validate(lawful)
    lines += out[:4]
    fired = ok
    lines.append(f"leg C (lawful receipt admits): {'FIRED' if fired else 'VACUOUS — refused lawful receipt'}")
    ok_all &= fired

    return ok_all, lines


def main(argv):
    if "--selftest" in argv:
        ok, lines = selftest()
        print("\n".join(lines))
        if not ok:
            print("VACUOUS GATE: selftest failed", file=sys.stderr)
            return 2
        print("selftest: PASS (all non-vacuity legs fired)")
        return 0

    if not argv:
        print("usage: validate_receipt.py <receipt.json> ... | --selftest", file=sys.stderr)
        return 2

    rc = 0
    for path in argv:
        ok, lines = validate(path)
        print("\n".join(lines))
        if not ok:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
