#!/usr/bin/env python3
"""Per-test timing budget gate (stdlib-only; shaped after scripts/bench_check.py
and gates/common.py).

Reads the TSV timing export written by SmaltTest.BudgetFormatter
(test/support/budget_formatter.ex):

    file:line<TAB>duration_ms<TAB>Case.test_name

and enforces every entry against the budget manifest
(docs/jira/v26.10.18/test_budgets.json, schema smalt-test-budget/v1):

    {"budgets": {"<Case.test>": {"tier": "default"|"stress", "max_ms": 1234}}}

Tier budgets: stress = 300_000 ms, default = 5_000 ms; explicit max_ms wins.

Fail-closed: missing/empty/malformed export, missing/invalid manifest,
unmanifested test, stale manifest entry (test absent from export), or any
breach => exit 1. --seed records the manifest from the current export
(first-run seeding; subsequent runs enforce).

Non-vacuity: before reporting, the gate runs two mutated fixtures of the
export (10x breach, unmanifested rename) through the same verdict function;
either one ACCEPTED => VACUOUS GATE, exit 1.
"""
import argparse, json, os, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXPORT = os.path.join(REPO, "tmp", "test-budget-export.tsv")
DEFAULT_MANIFEST = os.path.join(REPO, "docs", "jira", "v26.10.18", "test_budgets.json")
LINE_FIELDS = 3
TIERS = {"default": 5_000, "stress": 300_000}


def parse_export(path):
    """-> {test_id: (duration_ms, location)}; ValueError on malformed input."""
    if not os.path.exists(path):
        raise ValueError(f"missing export: {path} (run the budget formatter first)")
    out = {}
    with open(path) as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != LINE_FIELDS or not parts[1].isdigit() or ":" not in parts[2]:
                raise ValueError(f"{path}:{n}: malformed line: {line!r}")
            ms = int(parts[1])
            tid = parts[2]
            if tid in out:
                raise ValueError(f"{path}:{n}: duplicate test id {tid}")
            out[tid] = (ms, parts[0])
    if not out:
        raise ValueError(f"empty export: {path}")
    return out


def load_manifest(path):
    try:
        with open(path) as f:
            m = json.load(f)
    except FileNotFoundError:
        raise ValueError(f"missing manifest: {path} (seed with --seed)")
    except json.JSONDecodeError as e:
        raise ValueError(f"invalid manifest JSON: {e}")
    if not isinstance(m, dict) or m.get("schema") != "smalt-test-budget/v1":
        raise ValueError(f"manifest schema mismatch (want smalt-test-budget/v1): {path}")
    if not isinstance(m.get("budgets"), dict):
        raise ValueError(f"manifest 'budgets' must be an object: {path}")
    return m["budgets"]


def verdict(export, budgets):
    """-> (ok, details). Pure; reused verbatim on mutated fixtures."""
    details = []
    ok = True
    for tid, (ms, loc) in sorted(export.items()):
        b = budgets.get(tid)
        if b is None:
            ok = False
            details.append(f"UNMANIFESTED {tid} ({loc}, {ms}ms) -- re-seed or budget it")
            continue
        tier = b.get("tier", "default")
        max_ms = b.get("max_ms", TIERS.get(tier))
        if max_ms is None:
            ok = False
            details.append(f"BUDGET-UNKNOWN {tid}: tier {tier!r} not in {sorted(TIERS)}")
            continue
        if ms > max_ms:
            ok = False
            details.append(f"BREACH {tid}: {ms}ms > {max_ms}ms (tier {tier}, {loc})")
    for tid in sorted(set(budgets) - set(export)):
        ok = False
        details.append(f"STALE {tid}: in manifest but absent from export")
    return ok, details


def mutated_fixtures(export):
    breach = {t: (m * 10, l) for t, (m, l) in export.items()}
    unmanifested = {f"Vanished.Case:renamed_{t}": v for t, v in export.items()}
    return [("breach", breach), ("unmanifested", unmanifested)]


def main():
    ap = argparse.ArgumentParser(description="smalt per-test timing budget gate")
    ap.add_argument("--export", default=DEFAULT_EXPORT)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--seed", action="store_true",
                    help="record manifest from the current export (first run)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        export = parse_export(args.export)
    except ValueError as e:
        print(f"FAIL budget-gate/enforce export: {e}", file=sys.stderr)
        sys.exit(1)

    if args.seed:
        budgets = {}
        for tid, (ms, _loc) in export.items():
            if ms > TIERS["default"]:
                budgets[tid] = {"tier": "stress", "max_ms": ms}
            else:
                budgets[tid] = {"tier": "default"}
        os.makedirs(os.path.dirname(args.manifest), exist_ok=True)
        payload = {"schema": "smalt-test-budget/v1",
                   "seeded": time.strftime("%Y-%m-%d"),
                   "budgets": budgets}
        with open(args.manifest, "w") as f:
            json.dump(payload, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"seeded {len(budgets)} budgets -> {args.manifest}")
        sys.exit(0)

    try:
        budgets = load_manifest(args.manifest)
    except ValueError as e:
        print(f"FAIL budget-gate/manifest: {e}", file=sys.stderr)
        sys.exit(1)

    fixtures = []
    for name, mut in mutated_fixtures(export):
        fok, _ = verdict(mut, budgets)
        detected = not fok
        print(f"{'PASS' if detected else 'FAIL'} budget-gate/fixture:{name} "
              f"({'refused' if detected else 'ACCEPTED -- VACUOUS GATE'})")
        fixtures.append({"fixture": name, "detected": detected})

    ok, details = verdict(export, budgets)
    receipt = {
        "schema": "smalt-test-budget-gate/v1",
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "export": os.path.relpath(args.export, REPO),
        "manifest": os.path.relpath(args.manifest, REPO),
        "tests": len(export),
        "verdict": "PASS" if (ok and all(f["detected"] for f in fixtures)) else "FAIL",
        "fixtures": fixtures,
        "details": details,
    }
    with open(os.path.join(REPO, "tmp", "test-budget-gate-receipt.json"), "w") as f:
        json.dump(receipt, f, indent=2)

    if args.json:
        print(json.dumps(receipt, indent=2))
    else:
        print(f"== Test Budget Gate == ({len(export)} tests)")
        for d in details:
            print(f"  {d}")
        print(f"Gate: {receipt['verdict']}")
    sys.exit(0 if receipt["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
