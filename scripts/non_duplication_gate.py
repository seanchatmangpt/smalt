#!/usr/bin/env python3
"""non_duplication_gate.py — Non-Duplication Law gate (residual test/internal tier).

Scans test/internal/**/*.{ex,exs} for violations:
  R1  transport usage (absolute violations, never exempt): Plug.Test, :httpc,
      :hackney, :gun, Mint., Finch, Req.<verb>, :gen_tcp.send, Tesla.
  R2  Azure status literals (200|201|204|304|400|404|409|412|415|416|428|503)
      flagged only with same-line assert-verb co-occurrence (assert|refute|match?).
  R3  JSON-shape asserts: `assert ... == %{`, `match?(%{`, `Jason.decode`,
      `assert ... == ~s({`, `assert ... =~ "{"`.

Structural exemption (R2/R3 only, NEVER R1): stripped line contains
:sys.get_state / Process.whereis / :erlang.whereis / :erlang.processes / :proc_lib.

Typed exemptions live in scripts/non_duplication_classes.json:
  {"files": [{"path": ..., "reason": ...}], "functions": [{"name": ..., "reason": ...}]}
File/function exemptions mute R2/R3 only; R1 stays absolute.

Fail-closed: exit 1 on zero files scanned, unreadable file, or unreadable
classes file. Exit 0 only when every scanned line is clean.

WO: docs/jira/v26.10.19 (verification governance lane).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CLASSES = SCRIPT_DIR / "non_duplication_classes.json"

R1_PATTERNS = [
    ("Plug.Test", r"Plug\.Test"),
    (":httpc", r":httpc"),
    (":hackney", r":hackney"),
    (":gun", r":gun\b"),
    ("Mint.", r"Mint\."),
    ("Finch", r"\bFinch\b"),
    ("Req verb", r"\bReq\.(?:get|post|patch|put|delete)\b"),
    (":gen_tcp.send", r":gen_tcp\.send"),
    ("Tesla", r"\bTesla\b"),
]

R2_STATUS = re.compile(r"\b(200|201|204|304|400|404|409|412|415|416|428|503)\b")
R2_ASSERT = re.compile(r"\b(?:assert|refute)\b|match\?")

R3_PATTERNS = [
    ("assert == %{", r"==\s*%\{"),
    ("match?(%{", r"match\?\(\s*%\{"),
    ("Jason.decode", r"Jason\.decode"),
    ("assert == ~s({", r"==\s*~s\(\{"),
    ('assert =~ "{"', r'=~\s*"(\{)'),
]

STRUCTURAL_EXEMPT = [
    ":sys.get_state",
    "Process.whereis",
    ":erlang.whereis",
    ":erlang.processes",
    ":proc_lib",
]

DEF_RE = re.compile(r"^\s*def(?:p)?\s+([A-Za-z0-9_?!]+)")


def strip_comment(line: str) -> str:
    """Strip a `#` comment, respecting quotes so '#' inside a string survives."""
    out = []
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "#":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def load_classes(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[FAIL] unreadable classes file {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"[FAIL] classes file {path} is not a JSON object", file=sys.stderr)
        sys.exit(1)
    return data


def exempt_file(rel: str, classes: dict) -> bool:
    for entry in classes.get("files", []):
        p = str(entry.get("path", ""))
        if rel == p or rel.endswith("/" + p) or rel.endswith(p) and "/" in p:
            return True
        if rel.endswith("/" + p):
            return True
    return False


def iter_subject_files(args):
    if args:
        files = [Path(a) for a in args]
    else:
        root = SCRIPT_DIR.parent / "test" / "internal"
        if not root.is_dir():
            return []
        files = sorted(
            p for p in root.rglob("*")
            if p.is_file() and p.suffix in (".ex", ".exs")
        )
    return [f for f in files if f.is_file()]


def main(argv):
    classes_path = DEFAULT_CLASSES
    rest = list(argv[1:])
    if "--classes" in rest:
        i = rest.index("--classes")
        classes_path = Path(rest[i + 1])
        del rest[i : i + 2]
    args = [a for a in rest if not a.startswith("--")]
    classes = load_classes(classes_path)
    exempt_fns = {str(e.get("name", "")) for e in classes.get("functions", [])}

    files = iter_subject_files(args)
    if not files:
        print(
            "[FAIL] non-duplication gate scanned 0 files (tree absent or empty) — fail-closed",
            file=sys.stderr,
        )
        return 1

    violations = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"[FAIL] unreadable file {path}: {exc}", file=sys.stderr)
            return 1
        rel = str(path)
        file_exempt = exempt_file(rel, classes)
        current_fn = None
        for lineno, raw in enumerate(text.splitlines(), 1):
            line = strip_comment(raw)
            m = DEF_RE.match(line)
            if m:
                current_fn = m.group(1)
            # R1 — absolute, no exemptions of any kind.
            for label, pattern in R1_PATTERNS:
                if re.search(pattern, line):
                    violations.append(
                        f"{path}:{lineno}: R1 transport violation ({label}): {line.strip()}"
                    )
            if file_exempt:
                continue
            fn_exempt = current_fn in exempt_fns
            if fn_exempt or any(s in line for s in STRUCTURAL_EXEMPT):
                continue
            # R2 — status literal with assert-verb co-occurrence.
            if R2_STATUS.search(line) and R2_ASSERT.search(line):
                violations.append(
                    f"{path}:{lineno}: R2 Azure status literal in assert: {line.strip()}"
                )
            # R3 — JSON-shape asserts.
            for label, pattern in R3_PATTERNS:
                if re.search(pattern, line):
                    violations.append(
                        f"{path}:{lineno}: R3 JSON-shape assert ({label}): {line.strip()}"
                    )

    if violations:
        for v in violations:
            print(v)
        print(f"[FAIL] non-duplication gate: {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print(f"[PASS] non-duplication gate: {len(files)} file(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
