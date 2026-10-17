#!/usr/bin/env python3
"""KD flip tool — contract-keyed shim registry drives KNOWN_DIVERGENCES closure.

Mechanism (lane S-7, v26.10.14):

1. Shims mark the KD ids they cover at the edit site as a comment token:

     # KD-COVERS: KD-21,KD-49      (Elixir)
     // KD-COVERS: KD-15           (TS/JS)

   This tool scans lib/ and workspace/lib (overridable via --scan-root,
   repeatable) and builds a covers-map: KD id -> [(file, mtime)].

2. For each KD row with status OPEN whose id appears in the covers-map, the
   witness is the KD row's evidence path(s) (column 4 of the register). If an
   evidence receipt (or a newer file under the receipts dir mentioning the id)
   has mtime AFTER the newest shim mtime and shows a PASS verdict, the row is
   FLIP-ELIGIBLE. Otherwise (probe cannot run / no post-shim witness yet) it
   is FLIP-PENDING-WITNESS.

3. --apply updates KNOWN_DIVERGENCES.md status OPEN -> CLOSED-SIMULATED
   (meaning: shim landed, witness receipt at <path>) ONLY for FLIP-ELIGIBLE
   rows. Rows are never flipped on the tool's own judgement of code — only on
   a witnessed post-shim receipt.

4. Exit 1 listing any KD-COVERS token whose KD id is missing from the
   register (forces register sync). Unknown ids are NEVER flipped.

Read-only by default; mutates only with --apply.
"""

import argparse
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JIRA = ROOT / "docs/jira/v26.10.14"
KD_PATH = JIRA / "KNOWN_DIVERGENCES.md"
DEFAULT_SCAN_ROOTS = [ROOT / "lib", ROOT / "workspace/lib"]
RESULTS_DIR = JIRA / "sdk-results"


def receipt_dirs():
    """All milestone receipt windows + this register's sdk-results dir.

    The register may be closed (e.g. v26.10.14) while witness receipts land
    under the active window (docs/jira newest dir, e.g. v26.10.16); the
    mtime gate is what makes cross-window witnesses lawful, not the path.
    """
    return sorted((ROOT / "docs/jira").glob("v*/receipts")) + [RESULTS_DIR]

COVERS_RE = re.compile(r"(?:#|//).*?KD-COVERS:[ \t]*([A-Za-z0-9_,\- \t]+)")
KD_ROW_RE = re.compile(r"^\s*\|\s*(KD-\d+)\s*\|(.*)$")


def split_row(line):
    parts, cur, esc = [], "", False
    for ch in line.strip().strip("|"):
        if esc:
            cur += ch; esc = False
        elif ch == "\\":
            esc = True
        elif ch == "|":
            parts.append(cur.strip()); cur = ""
        else:
            cur += ch
    parts.append(cur.strip())
    return parts


def load_register():
    """KD id -> {line_no, parts, status, evidence}."""
    rows = {}
    for i, line in enumerate(KD_PATH.read_text(errors="replace").splitlines(), 1):
        m = KD_ROW_RE.match(line)
        if not m:
            continue
        parts = split_row(line)
        if len(parts) < 6:
            continue
        # trailing prose may follow; empty cell -> empty status (not a KD row crash)
        sm = re.match(r"[A-Za-z-]+", parts[5].strip())
        status = sm.group(0) if sm else ""
        rows[m.group(1)] = {
            "line_no": i,
            "parts": parts,
            "status": status,
            "evidence": parts[3],
        }
    return rows


def scan_covers(scan_roots):
    """covers-map: KD id -> {file: newest mtime}."""
    covers = {}
    for root in scan_roots:
        if not root.exists():
            continue
        for p in sorted(root.rglob("*")):
            if p.suffix not in (".ex", ".exs", ".js", ".mjs", ".cjs", ".ts", ".py"):
                continue
            try:
                text = p.read_text(errors="replace")
            except OSError:
                continue
            for m in COVERS_RE.finditer(text):
                for tok in re.split(r"[,\s]+", m.group(1)):
                    tok = tok.strip()
                    if not tok:
                        continue
                    entry = covers.setdefault(tok, {})
                    mt = p.stat().st_mtime
                    if p not in entry or mt > entry[p]:
                        entry[p] = mt
    return covers


def evidence_paths(evidence_field):
    """Extract repo-relative doc paths from the evidence column."""
    paths = []
    for m in re.finditer(r"([\w./-]+\.(?:md|log|json))", evidence_field):
        rel = m.group(1)
        for base in (JIRA, ROOT):
            p = base / rel if not rel.startswith("docs/") else ROOT / rel
            if p.exists():
                paths.append(p)
                break
    return paths


def shows_pass(path, kid):
    text = path.read_text(errors="replace")
    has_pass = bool(re.search(r"\bPASS\b", text))
    # a FAIL/DIVERGENCE verdict row naming this id negates
    negated = bool(re.search(
        rf"^\s*\|.*{re.escape(kid)}\b.*\*\*?(FAIL|DIVERGENCE)", text, re.M))
    return has_pass and not negated


def witness(kid, evidence_field, shim_mtime):
    """Return (verdict, witness_path_or_reason).

    FLIP-ELIGIBLE: a receipt/probe artifact newer than the newest shim file,
    showing a pass for this id. Otherwise FLIP-PENDING-WITNESS.
    """
    candidates = evidence_paths(evidence_field)
    for base in receipt_dirs():
        if not base.exists():
            continue
        for p in base.iterdir():
            if p.is_file() and kid in p.read_text(errors="replace"):
                candidates.append(p)
    best = None
    for p in sorted(set(candidates)):
        mt = p.stat().st_mtime
        if mt <= shim_mtime:
            continue
        if shows_pass(p, kid):
            best = p  # newest qualifying witness wins
    if best is not None:
        try:
            rel = str(best.relative_to(ROOT))
        except ValueError:
            rel = str(best)
        return "FLIP-ELIGIBLE", rel
    if candidates:
        return "FLIP-PENDING-WITNESS", (
            "no post-shim receipt newer than shim mtime "
            f"({time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(shim_mtime))})")
    return "FLIP-PENDING-WITNESS", "no witness artifact found (probe cannot run / no env)"


def flip_line(line, witness_path):
    """OPEN -> CLOSED-SIMULATED in one table row, preserving the rest."""
    parts = split_row(line)
    parts[5] = (
        f"CLOSED-SIMULATED (shim landed, witness receipt at {witness_path})"
    )
    return "| " + " | ".join(parts) + " |"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="flip FLIP-ELIGIBLE OPEN rows to CLOSED-SIMULATED")
    ap.add_argument("--scan-root", action="append", default=None,
                    help="extra scan root (repeatable); default lib/ + workspace/lib")
    args = ap.parse_args()

    scan_roots = list(DEFAULT_SCAN_ROOTS)
    for r in (args.scan_root or []):
        scan_roots.append(Path(r).resolve())

    register = load_register()
    covers = scan_covers(scan_roots)

    unknown = sorted(k for k in covers if k not in register)
    eligible, pending = [], []
    for kid in sorted(covers):
        if kid in unknown:
            continue
        row = register[kid]
        if row["status"] != "OPEN":
            continue
        shim_mtime = max(covers[kid].values())
        verdict, why = witness(kid, row["evidence"], shim_mtime)
        (eligible if verdict == "FLIP-ELIGIBLE" else pending).append((kid, why))

    print(f"KD-COVERS covers-map: {len(covers)} KD ids "
          f"from {sum(len(v) for v in covers.values())} files")
    def display(p):
        try:
            return str(p.relative_to(ROOT))
        except ValueError:
            return str(p)

    for kid in sorted(covers):
        files = ", ".join(display(p) for p in covers[kid])
        status = register[kid]["status"] if kid in register else "MISSING-FROM-REGISTER"
        print(f"  {kid}: [{status}] {files}")

    print(f"\nFLIP-ELIGIBLE: {len(eligible)}")
    for kid, why in eligible:
        print(f"  {kid}: witness {why}")
    print(f"FLIP-PENDING-WITNESS: {len(pending)}")
    for kid, why in pending:
        print(f"  {kid}: {why}")

    if unknown:
        print(f"\nUNKNOWN KD IDS in KD-COVERS tokens (register sync required): "
              f"{', '.join(unknown)}")

    if args.apply:
        if unknown:
            print("\n--apply REFUSED: unknown KD ids present; sync the register first.")
            sys.exit(1)
        if not eligible:
            print("\n--apply: nothing FLIP-ELIGIBLE; register unchanged.")
        else:
            lines = KD_PATH.read_text(errors="replace").splitlines()
            eligible_ids = {k for k, _ in eligible}
            flipped = 0
            for kid in sorted(eligible_ids):
                ln = register[kid]["line_no"] - 1
                _, why = next(e for e in eligible if e[0] == kid)
                lines[ln] = flip_line(lines[ln], why)
                flipped += 1
            KD_PATH.write_text("\n".join(lines) + "\n")
            print(f"\n--apply: flipped {flipped} row(s) OPEN -> CLOSED-SIMULATED: "
                  f"{', '.join(sorted(eligible_ids))}")

    sys.exit(1 if unknown else 0)


if __name__ == "__main__":
    main()
