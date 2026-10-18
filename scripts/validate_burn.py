#!/usr/bin/env python3
"""validate_burn.py — AZB-03 burn JSONL receipt validator (fail-closed gate).

Usage:
  python3 scripts/validate_burn.py [--gate] <file.jsonl> [<file.jsonl> ...]

A burn JSONL file carries three line kinds:
  {"type": "run_header", ...}   first line: run id + the EXPECTED matrix
                                (containers x cycles x stages) that --gate
                                checks every (container,cycle,stage) cell
                                against. Without a declared matrix a dropped
                                cycle is invisible (the AZB-03 falsifier), so
                                --gate REFUSES a file whose header is missing.
  {"type": "run_receipt", ...}  one run summary, validated against
                                ~/.zcode/dfcm/receipt.schema.json.
  {"schema": "smalt-burn/v2"}   burn rows, validated against
                                docs/jira/v26.10.18/burn/burn-row.schema.json.

Exit codes: 0 valid; 1 validation failure (schema violation, MISSING_CELL,
DIRTY_ROW, or receipt-schema mismatch); 2 usage/IO error.
"""
import argparse
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROW_SCHEMA = os.path.join(REPO, "docs/jira/v26.10.18/burn/burn-row.schema.json")
RECEIPT_SCHEMA = os.path.expanduser("~/.zcode/dfcm/receipt.schema.json")

try:
    import jsonschema
except ImportError:  # pragma: no cover
    jsonschema = None


def die(msg):
    print("[VALIDATE-BURN] %s" % msg)
    sys.exit(1)


def load_schemas():
    with open(ROW_SCHEMA) as f:
        row_schema = json.load(f)
    with open(RECEIPT_SCHEMA) as f:
        receipt_schema = json.load(f)
    if jsonschema is None:
        die("jsonschema module unavailable — refusing to validate (fail-closed)")
    return row_schema, receipt_schema


def validate_file(path, row_schema, receipt_schema, gate):
    errors = []
    header = None
    receipt = None
    rows = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                errors.append("line %d: not valid JSON: %s" % (lineno, e))
                continue
            if not isinstance(obj, dict):
                errors.append("line %d: not a JSON object" % lineno)
                continue
            t = obj.get("type")
            if t == "run_header":
                if header is not None:
                    errors.append("line %d: duplicate run_header" % lineno)
                header = obj
            elif t == "run_receipt":
                if receipt is not None:
                    errors.append("line %d: duplicate run_receipt" % lineno)
                receipt = obj
            else:
                rows.append((lineno, obj))

    # 1. Row schema validation (every line kind of row).
    validator = jsonschema.Draft202012Validator(row_schema)
    for lineno, row in rows:
        for err in sorted(validator.iter_errors(row), key=str):
            errors.append("line %d: SCHEMA_VIOLATION %s" % (lineno, err.message))

    # 2. Run receipt against the DfCM receipt schema (required in gate mode;
    # a bare row file validates rows only).
    if receipt is None:
        if gate:
            errors.append("missing run_receipt line (R_missing_consequence)")
    else:
        rvalidator = jsonschema.Draft202012Validator(receipt_schema)
        for err in sorted(rvalidator.iter_errors(receipt), key=str):
            errors.append("RECEIPT_SCHEMA_VIOLATION %s" % err.message)

    # 3. Gate-only checks: expected matrix coverage + verdicts.
    if gate:
        exp = (header or {}).get("expected") or {}
        containers = exp.get("containers")
        cycles = exp.get("cycles")
        stages = exp.get("stages")
        if not (containers and cycles and stages):
            errors.append(
                "EXPECTED_MATRIX_MISSING: no run_header with "
                "expected.{containers,cycles,stages} — a dropped cycle would be invisible"
            )
        else:
            seen = set()
            for _, row in rows:
                seen.add((row.get("container"), row.get("cycle"), row.get("stage")))
                if row.get("verdict") != "CLEAN":
                    errors.append(
                        "DIRTY_ROW container=%s cycle=%s stage=%s verdict=%s broken_term=%s"
                        % (
                            row.get("container"),
                            row.get("cycle"),
                            row.get("stage"),
                            row.get("verdict"),
                            row.get("broken_term"),
                        )
                    )
            for c in containers:
                for cy in cycles:
                    for st in stages:
                        if (c, cy, st) not in seen:
                            errors.append(
                                "MISSING_CELL container=%s cycle=%s stage=%s" % (c, cy, st)
                            )
    return errors


def main():
    ap = argparse.ArgumentParser(description="AZB-03 burn JSONL validator")
    ap.add_argument("--gate", action="store_true",
                    help="also check expected-matrix coverage and refuse any non-CLEAN row")
    ap.add_argument("--row-schema", default=ROW_SCHEMA)
    ap.add_argument("--receipt-schema", default=RECEIPT_SCHEMA)
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    row_schema, receipt_schema = load_schemas()
    any_error = False
    for path in args.files:
        try:
            errors = validate_file(path, row_schema, receipt_schema, args.gate)
        except OSError as e:
            print("[VALIDATE-BURN] %s: %s" % (path, e))
            any_error = True
            continue
        if errors:
            any_error = True
            for e in errors:
                print("[VALIDATE-BURN] %s: %s" % (path, e))
        else:
            print("[VALIDATE-BURN] %s: OK" % path)
    sys.exit(1 if any_error else 0)


if __name__ == "__main__":
    main()
