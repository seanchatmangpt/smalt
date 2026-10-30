#!/usr/bin/env python3
"""POSH-009 SDK-parity coverage gate (lane F7).

Derives the surface inventory MECHANICALLY from source (never hand-listed):

  1. posh op registry      -- ``var ops = map[string]server.Handler{...}`` in
                              posh/cmd/posh/main.go (cells ``op:<name>``)
  2. provider resources    -- ``resp.TypeName = req.ProviderTypeName + "_X"``
                              in internal/provider/resource_*.go (cells
                              ``resource:azurerm_X``)
  3. provider data sources -- same pattern in internal/provider/data_source*.go
                              (cells ``datasource:azurerm_X``)

Gate semantics: every cell must be PASS (matched by no KD row) or covered by a
registered KD-nn row in posh/KNOWN_DIVERGENCES.md. Any cell that is neither is
loudly MISSING and exits 1 -- silent gaps fail.

``--self-test`` injects a bogus op into the inventory before compare and must
flip the gate to exit 1 (otherwise the gate is VACUOUS), then verifies the
re-derived inventory is byte-identical to the baseline (restore check).

Exit codes: 0 = all cells PASS or REGISTERED; 1 = MISSING cells (or, under
--self-test, a failure of the flip/restore contract); 2 = harness error.
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MAIN_GO = REPO / "posh" / "cmd" / "posh" / "main.go"
PROVIDER_DIR = REPO / "adapters" / "terraform-provider-smalt" / "internal" / "provider"
KD_FILE = REPO / "posh" / "KNOWN_DIVERGENCES.md"

OPS_RE = re.compile(r'^\s*"([a-z0-9_]+)":\s*\w+Op,?\s*$', re.M)
TYPENAME_RE = re.compile(
    r'resp\.TypeName\s*=\s*req\.ProviderTypeName\s*\+\s*"_([a-z0-9_]+)"'
)
KD_ROW_RE = re.compile(r"^\|\s*(KD-\d+)\s*\|", re.M)
CELL_GLOB_RE = re.compile(r"^\|\s*KD-\d+\s*\|([^|]*)\|")
PASS_ROW_RE = re.compile(r"^\|\s*PASS\s*\|([^|]+)\|")
BOGUS_OP = "bogus_op_selftest"


def parse_ops(main_go: Path) -> set[str]:
    text = main_go.read_text()
    m = re.search(r"var ops = map\[string\]server\.Handler\{(.*?)\n\}", text, re.S)
    body = m.group(1) if m else text
    return set(OPS_RE.findall(body))


def parse_typenames(directory: Path, filename_glob: str) -> set[str]:
    names: set[str] = set()
    for f in sorted(directory.glob(filename_glob)):
        if f.name.endswith("_test.go"):
            continue
        names |= set(TYPENAME_RE.findall(f.read_text()))
    return names


def parse_kd_rows(kd_file: Path) -> dict[str, list[str]]:
    """Returns {KD-id: [cell globs]} parsed from the register's KD table."""
    text = kd_file.read_text()
    rows: dict[str, list[str]] = {}
    for line in text.splitlines():
        m = re.match(r"^\|\s*(KD-\d+)\s*\|([^|]+)\|", line)
        if m:
            globs = [g.strip() for g in m.group(2).split(",")]
            rows[m.group(1)] = globs
    return rows


def parse_pass_rows(kd_file: Path) -> set[str]:
    """Returns exact cells listed in the register's PASS ledger (§4.1)."""
    cells = set()
    for line in kd_file.read_text().splitlines():
        m = PASS_ROW_RE.match(line)
        if m:
            cells.add(m.group(1).strip())
    return cells


def classify(cells: set[str], kd_rows: dict[str, list[str]], pass_cells: set[str]):
    registered, passed, missing = [], [], []
    for cell in sorted(cells):
        matched = [
            kd_id
            for kd_id, globs in kd_rows.items()
            if any(fnmatch.fnmatch(cell, g) for g in globs)
        ]
        if matched:
            registered.append((cell, matched))
        elif cell in pass_cells:
            passed.append(cell)
        else:
            missing.append(cell)
    return registered, passed, missing


def build_inventory() -> set[str]:
    ops = parse_ops(MAIN_GO)
    resources = parse_typenames(PROVIDER_DIR, "resource_*.go")
    datasources = parse_typenames(PROVIDER_DIR, "data_source*.go")
    cells = {f"op:{o}" for o in ops}
    cells |= {f"resource:azurerm_{n}" for n in resources}
    cells |= {f"datasource:azurerm_{n}" for n in datasources}
    return cells


def run_gate(inventory: set[str]) -> tuple[int, list[str]]:
    kd_rows = parse_kd_rows(KD_FILE)
    pass_cells = parse_pass_rows(KD_FILE)
    registered, passed, missing = classify(inventory, kd_rows, pass_cells)
    for cell, kd_ids in registered:
        print(f"REGISTERED {cell} ({','.join(kd_ids)})")
    for cell in passed:
        print(f"PASS       {cell}")
    for cell in missing:
        print(f"MISSING    {cell} -- register a KD row or fix the surface")
    print(
        f"coverage: {len(registered)} registered / {len(passed)} pass / "
        f"{len(missing)} missing / {len(inventory)} cells; KD rows: {len(kd_rows)}"
    )
    return (1 if missing else 0), missing


def self_test() -> int:
    inventory = build_inventory()
    baseline_rc, baseline_missing = run_gate(inventory)
    print(f"self-test baseline gate exit: {baseline_rc}")

    injected = set(inventory) | {f"op:{BOGUS_OP}"}
    injected_rc, injected_missing = run_gate(injected)
    injected_missing_names = [c for c in injected_missing if BOGUS_OP in c]
    if injected_rc == 0 or not injected_missing_names:
        print(
            "SELF-TEST FAIL: bogus op did NOT flip the gate to exit 1 "
            "(VACUOUS GATE)"
        )
        return 1
    print(f"self-test injected gate exit: {injected_rc} (flip witnessed)")

    restored = build_inventory()
    if restored != inventory:
        print("SELF-TEST FAIL: inventory did not restore after injection")
        return 1
    print("SELF-TEST PASS: flip + restore verified")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="POSH-009 coverage gate")
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="inject a bogus op, require the gate to flip to exit 1, restore",
    )
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    rc, _ = run_gate(build_inventory())
    return rc


if __name__ == "__main__":
    sys.exit(main())
