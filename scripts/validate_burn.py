#!/usr/bin/env python3
"""validate_burn.py — AZB-03 burn JSONL receipt validator (fail-closed gate).

Usage:
  python3 scripts/validate_burn.py [--gate] [--self-check] <file.jsonl> [<file.jsonl> ...]

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

Standing law (azb-18 named defect): the run_receipt standing is NOT taken from
the replay command exit alone. The validator re-derives standing from the
plane rows: all rows clean:true => ALIVE; any row not clean => PARTIAL_ALIVE
with the failing rows named. An ALIVE claim over dirty rows is refused
(STANDING_REFUSED, exit 1) — fail-closed.

Exit codes: 0 valid; 1 validation failure (schema violation, MISSING_CELL,
DIRTY_ROW, STANDING_REFUSED, or receipt-schema mismatch); 2 usage/IO error.
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


def derive_standing(rows):
    """Standing derived from the plane rows (not the replay exit).

    All rows clean => ('ALIVE', []); any non-clean row =>
    ('PARTIAL_ALIVE', [row descriptors]). Empty rows => ('UNKNOWN', []).
    """
    dirty = []
    for row in rows:
        if row.get("clean") is not True or row.get("verdict") != "CLEAN":
            dirty.append(
                "container=%s cycle=%s stage=%s verdict=%s broken_term=%s"
                % (
                    row.get("container"),
                    row.get("cycle"),
                    row.get("stage"),
                    row.get("verdict"),
                    row.get("broken_term"),
                )
            )
    if not rows:
        return "UNKNOWN", dirty
    return ("ALIVE" if not dirty else "PARTIAL_ALIVE"), dirty


def validate_file(path, row_schema, receipt_schema, gate, check_receipt=True):
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
    elif check_receipt:
        rvalidator = jsonschema.Draft202012Validator(receipt_schema)
        for err in sorted(rvalidator.iter_errors(receipt), key=str):
            errors.append("RECEIPT_SCHEMA_VIOLATION %s" % err.message)

    # 3. Standing law: re-derive standing from the plane rows. An ALIVE
    # claim over dirty rows is a typed refusal (fail-closed).
    derived, dirty = derive_standing([row for _, row in rows])
    if receipt is not None:
        claimed = (receipt.get("standing") or {}).get("value")
        if claimed == "ALIVE":
            if derived == "UNKNOWN":
                errors.append(
                    "STANDING_REFUSED: ALIVE claimed but no burn rows present "
                    "to derive it from (R_missing_consequence)"
                )
            elif derived != "ALIVE":
                errors.append(
                    "STANDING_REFUSED: ALIVE claimed over dirty rows "
                    "(derived standing PARTIAL_ALIVE); failing rows: %s"
                    % "; ".join(dirty)
                )

    # 4. Gate-only checks: expected matrix coverage + verdicts.
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
    return errors, derived, dirty


def _self_check(row_schema, receipt_schema):
    """Non-vacuity fixture: a clean 2-row run derives ALIVE; the same file
    mutated so one row carries clean:false must derive PARTIAL_ALIVE and the
    ALIVE claim must be refused (STANDING_REFUSED, exit 1)."""
    tmpdir = None
    import tempfile

    tmpdir = tempfile.mkdtemp(prefix="validate-burn-selfcheck-")
    clean_rows = [
        {
            "schema": "smalt-burn/v2",
            "subject_sha": "deadbeef",
            "image_digest": "smalt-burn@sha256:" + "0" * 64,
            "container": "smalt-self-control",
            "plane": "control",
            "cycle": 1,
            "stage": "soak",
            "verdict": "CLEAN",
            "t_start": "2026-10-19T00:00:00Z",
            "t_end": "2026-10-19T00:01:00Z",
            "exit_code": 0,
            "orphans": [],
            "crash_reports": 0,
            "evidence_path": "tmp/selfcheck",
            "broken_term": None,
            "clean": True,
        },
        {
            "schema": "smalt-burn/v2",
            "subject_sha": "deadbeef",
            "image_digest": "smalt-burn@sha256:" + "0" * 64,
            "container": "smalt-self-data",
            "plane": "data",
            "cycle": 1,
            "stage": "soak",
            "verdict": "CLEAN",
            "t_start": "2026-10-19T00:00:00Z",
            "t_end": "2026-10-19T00:01:00Z",
            "exit_code": 0,
            "orphans": [],
            "crash_reports": 0,
            "evidence_path": "tmp/self-check",
            "broken_term": None,
            "clean": True,
        },
    ]
    receipt = {
        "type": "run_receipt",
        "standing": {"value": "ALIVE", "derived_from": "self-check"},
    }
    header = {"type": "run_header", "expected": {"containers": ["smalt-self-control", "smalt-self-data"], "cycles": [1], "stages": ["soak"]}}

    def write(name, rows):
        p = os.path.join(tmpdir, name)
        with open(p, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
            f.write(json.dumps(receipt) + "\n")
        return p

    clean_path = write("clean.jsonl", clean_rows)
    dirty_rows = [dict(clean_rows[0])]
    dirty_rows[0] = dict(dirty_rows[0], clean=False, verdict="UNHANDLED_EXIT",
                         broken_term="mu_unlawful", exit_code=137)
    dirty_path = write("dirty.jsonl", clean_rows[:1] + [dirty_rows[0]] + clean_rows[1:])

    ok = True
    errs, derived, _ = validate_file(clean_path, row_schema, receipt_schema, gate=False, check_receipt=False)
    print("[VALIDATE-BURN] self-check clean: derived=%s errors=%d" % (derived, len(errs)))
    if derived != "ALIVE" or errs:
        ok = False
    errs, derived, dirty = validate_file(dirty_path, row_schema, receipt_schema, gate=False, check_receipt=False)
    refused = any(e.startswith("STANDING_REFUSED") for e in errs)
    print("[VALIDATE-BURN] self-check dirty: derived=%s refused=%s failing=%s"
          % (derived, refused, "; ".join(dirty)))
    if derived != "PARTIAL_ALIVE" or not refused:
        ok = False
    import shutil

    shutil.rmtree(tmpdir, ignore_errors=True)
    if not ok:
        die("self-check FAILED — mutated observation did not flip the standing (vacuous gate)")
    print("[VALIDATE-BURN] self-check PASS")


def main():
    ap = argparse.ArgumentParser(description="AZB-03 burn JSONL validator")
    ap.add_argument("--gate", action="store_true",
                    help="also check expected-matrix coverage and refuse any non-CLEAN row")
    ap.add_argument("--self-check", action="store_true",
                    help="run the non-vacuity fixture (clean=ALIVE, one clean:false row "
                         "=> PARTIAL_ALIVE + STANDING_REFUSED) instead of validating files")
    ap.add_argument("--row-schema", default=ROW_SCHEMA)
    ap.add_argument("--receipt-schema", default=RECEIPT_SCHEMA)
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()

    row_schema, receipt_schema = load_schemas()
    if args.self_check:
        _self_check(row_schema, receipt_schema)
        return

    if not args.files:
        ap.error("no input files given (or use --self-check)")
    any_error = False
    for path in args.files:
        try:
            errors, derived, dirty = validate_file(path, row_schema, receipt_schema, args.gate)
        except OSError as e:
            print("[VALIDATE-BURN] %s: %s" % (path, e))
            any_error = True
            continue
        if dirty:
            print("[VALIDATE-BURN] %s: derived_standing=PARTIAL_ALIVE failing_rows=[%s]"
                  % (path, "; ".join(dirty)))
        else:
            print("[VALIDATE-BURN] %s: derived_standing=%s" % (path, derived))
        if errors:
            any_error = True
            for e in errors:
                print("[VALIDATE-BURN] %s: %s" % (path, e))
        else:
            print("[VALIDATE-BURN] %s: OK" % path)
    sys.exit(1 if any_error else 0)


if __name__ == "__main__":
    main()
