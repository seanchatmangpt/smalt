#!/usr/bin/env python3
"""receipt_standing_lint.py — Gate 3 (receipt-standing-law) port to smalt.

Port of cgap scripts/receipt_standing_lint.py (commit 8d15fcca; ggen Gate-3
ancestor scripts/receipt_lint.py from lane L21). The smalt naming is kept
identical to cgap's: smalt owns scripts/receipt_index.py (lane 13,
RECEIPTS.md/INDEX.md regeneration + SUSPECT evidence census) — a DIFFERENT
tool that extracts standing lines it already understands and checks for real
command output. This lint COMPOSES with it, it does not supersede it:

  - receipt_index.py: does the receipt's standing claim carry real evidence?
    (SUSPECT census, wired into receipt-index-check / receipt-durability-gate)
  - receipt_standing_lint.py: does the receipt carry a parseable standing
    line at all, in the closed standing vocabulary? (receipt-standing-law)

A receipt can be standing-clean here and still SUSPECT there, and vice versa.

Scans receipt *.md files for a parseable standing line using the accepted
synonym keys (Standing|Status|verdict|Result|Exit code) and the closed
standing vocabulary from ~/.claude/rules/receipt-standing-law.md. Missing or
unparseable standing -> FAIL naming the file, exit 1.

--backfill prints proposed insertions as diffs; never writes (canonical
  behavior). --write (smalt addition, used ONCE for the initial batched
  backfill) inserts the proposed line directly, per the law's insert rule:
  quote only standing vocabulary already present in the file's head; else
  insert `Standing: UNVERIFIED`. One line per file, immediately after the H1.
Emits a standing-map hash so vocabulary changes re-trigger backfill
consciously, and writes docs/jira/receipt-standing-map.json.

Smalt targets: docs/jira/v*/receipts/**. Standing map:
docs/jira/receipt-standing-map.json.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

# Gate 3 accepted synonym keys (case-insensitive, line-start).
KEY_SYNONYMS = [
    "Standing", "Status", "verdict", "Result",
    "Exit-code", "Exit code", "Gate",
]
KEY_RE = re.compile(
    r"^#?\s*(" + "|".join(KEY_SYNONYMS) + r")\s*[:=]\s*(.+)$",
    re.IGNORECASE,
)

# Gate 3 / receipt-standing-law closed vocabulary. UNVERIFIED always lintable
# (the lawful fallback for backfills with no present vocabulary).
STANDING_VOCAB_CORE = [
    "ALIVE", "PARTIAL_ALIVE", "PARTIAL", "BLOCKED", "UNVERIFIED", "PASS",
]
# Smalt extension (documented divergence from ggen Gate-3 map): standing
# tokens already recognized by smalt's receipt_index.py + observed standing
# spellings in smalt's existing receipt corpus. Keeping these lintable means
# the initial census FAILs only genuinely broken receipts, not 900 files of
# lawful pre-existing standing claims in smalt's local vocabulary.
STANDING_VOCAB_SMALT_EXT = [
    "FAIL", "FAIL-HONEST", "UNKNOWN", "VERIFIED", "REFUSED", "UNSUPPORTED",
    "CLOSED", "CLOSED-SIMULATED", "CLOSED-WITH-EVIDENCE", "OPEN",
    "LANDED", "COMPLETE", "DECIDED", "BUILD_BROKEN", "CONFORMANT",
    "SUSPECT", "PROVISIONAL", "PROVISIONAL_ALIVE", "SKIP-LOUD",
    "NON-VACUOUS", "TYPED-RED", "TYPED_RECOMMENDATION", "RESOLVED",
    "SUPERSEDED-BY-OPERATOR", "GREEN", "KEEP", "DONE", "CENSUS",
    "NOT-REPRODUCIBLE", "FLAKE_SOLO", "RED",
]
STANDING_VOCAB = STANDING_VOCAB_CORE + STANDING_VOCAB_SMALT_EXT

# `Exit code: 0` / `Exit-code: 0` -> Exit-code-0 (spec value family).
EXIT_CODE_VALUE_RE = re.compile(r"^\d+$")

REPO = Path(__file__).resolve().parent.parent

# Receipts surfaces this repo owns (docs/jira/v*/receipts/**).
DEFAULT_TARGETS = [
    *sorted((REPO / "docs" / "jira").glob("*/receipts"),
            key=lambda p: p.name, reverse=True),
]
STANDING_MAP_PATH = REPO / "docs" / "jira" / "receipt-standing-map.json"

BACKFILL_SCAN_LINES = 5


def standing_map_hash() -> str:
    """Hash of the accepted-vocabulary map (keys + values + exit-code rule)."""
    h = hashlib.sha256()
    h.update(json.dumps(
        {"keys": KEY_SYNONYMS, "values": STANDING_VOCAB,
         "exit_code_rule": "Exit-code: N -> Exit-code-N",
         "annotation_strip": [
             "backticks", "parenthesized-suffix",
             "markdown-emphasis", "trailing-punctuation"],
        },
        sort_keys=True,
    ).encode())
    return h.hexdigest()[:16]


def strip_annotation(value: str) -> tuple[str, str]:
    """Strip backticks, markdown emphasis, punctuation and parenthesized
    suffixes from a standing value token.

    VERIFIED(9/9) -> (VERIFIED, 9/9); `PASS` -> (PASS, "");
    **ALIVE** -> ALIVE; PASS. -> PASS; **ALIVE** — summary -> ALIVE.
    """
    v = value.strip().strip("`").strip()
    annotation = ""
    m = re.match(r"^(\S+?)\(([^()]*)\)\s*$", v)
    if m:
        v = m.group(1)
        annotation = m.group(2)
    # first whitespace-delimited token only
    v = v.split()[0] if v.split() else ""
    v = v.strip("`")
    v = re.sub(r"^\*+|\*+$", "", v)      # markdown emphasis (**ALIVE**)
    v = v.rstrip(".,:;")
    return v, annotation


def parse_standing(line_value: str) -> tuple[str | None, str, str]:
    """Return (standing, annotation, reason) or (None, "", reason)."""
    v, ann = strip_annotation(line_value)
    if v.startswith("Exit-code-"):  # already normalized
        return v, ann, "exit-code"
    if EXIT_CODE_VALUE_RE.match(v):
        return "Exit-code-%s" % v, ann, "exit-code"
    if v in STANDING_VOCAB:
        return v, ann, "vocab"
    return None, "", "value '%s' not in vocabulary" % v


def parse_file(path: Path) -> dict:
    """Parse one receipt file into a standing-map entry."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as e:
        return {"file": str(path), "ok": False,
                "reason": "unreadable: %s" % e}

    for i, line in enumerate(lines):
        m = KEY_RE.match(line)
        if m:
            standing, ann, err = parse_standing(m.group(2))
            if standing is None:
                return {
                    "file": str(path), "key": m.group(1), "standing": None,
                    "annotation": "", "ok": False,
                    "reason": "line %d: %s" % (i + 1, err),
                }
            return {
                "file": str(path), "key": m.group(1), "standing": standing,
                "annotation": ann, "ok": True, "line": i + 1,
            }
    return {"file": str(path), "ok": False,
            "reason": "no parseable standing line"}


def _insert_after_h1(lines: list[str]) -> int:
    """Index to insert a standing line at: immediately after the H1, or as
    line 0 if the file has no H1."""
    for i, ln in enumerate(lines[:20]):
        if ln.startswith("# ") and not ln.startswith("##"):
            return i + 1
    return 0


def backfill_value(lines: list[str]) -> str | None:
    """First standing-vocabulary token present in the file head, else None
    (caller falls back to UNVERIFIED)."""
    head = lines[:BACKFILL_SCAN_LINES + _insert_after_h1(lines) or
                 BACKFILL_SCAN_LINES]
    for ln in head:
        for tok in ln.replace("*", " ").replace("`", " ").split():
            if tok.rstrip(".,:;") in STANDING_VOCAB:
                return tok.rstrip(".,:;")
    return None


def backfill_proposal(path: Path) -> tuple[str | None, str]:
    """Proposed standing value + unified-diff-style proposal string.

    Value: vocabulary token already present in the head, else UNVERIFIED.
    """
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None, ""
    value = backfill_value(lines) or "UNVERIFIED"
    i = _insert_after_h1(lines)
    name = "/".join(path.parts[-3:])
    if i >= len(lines):
        proposal = "\n".join([
            "--- a/%s" % name,
            "+++ b/%s (proposed, not written)" % name,
            "@@ -0,0 +1 @@",
            "+Standing: %s" % value,
        ])
    else:
        proposal = "\n".join([
            "--- a/%s" % name,
            "+++ b/%s (proposed, not written)" % name,
            "@@ -%d,0 +%d,1 @@" % (i, i + 1),
            "+Standing: %s" % value,
        ])
    return value, proposal


def apply_backfill(path: Path) -> str:
    """Write the proposed standing line (smalt batched-backfill mode)."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    value = backfill_value(lines) or "UNVERIFIED"
    i = _insert_after_h1(lines)
    lines.insert(i, "Standing: %s" % value)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return value


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("targets", nargs="*", default=None,
                    help="receipt files or dirs (default: docs/jira/*/receipts)")
    ap.add_argument("--backfill", action="store_true",
                    help="print proposed Standing insertions as diffs; never writes")
    ap.add_argument("--write", action="store_true",
                    help="apply the proposed insertions to the files "
                         "(smalt batched-backfill mode)")
    args = ap.parse_args()

    targets = [Path(t) for t in args.targets] if args.targets else DEFAULT_TARGETS
    files: list[Path] = []
    for t in targets:
        if t.is_dir():
            files.extend(sorted(t.rglob("*.md")))
        elif t.suffix == ".md":
            files.append(t)
        else:
            print("receipt-standing-lint: skipping non-.md target: %s" % t,
                  file=sys.stderr)
    files = sorted(set(files))
    # INDEX.md is a generated artifact (receipt_index.py writes it as a side
    # effect) — it carries no standing line by design; never lint it.
    files = [f for f in files if f.name != "INDEX.md"]

    results = [parse_file(f) for f in files]
    failures = [r for r in results if not r["ok"]]

    print("receipt-standing-lint: standing-map hash %s" % standing_map_hash())
    print("receipt-standing-lint: %d files, %d parse OK, %d FAIL"
          % (len(results), len(results) - len(failures), len(failures)))

    map_data = {
        "standing_map_hash": standing_map_hash(),
        "generated_by": "scripts/receipt_standing_lint.py",
        "entries": {r["file"]: {
            "standing": r.get("standing"),
            "key": r.get("key"),
            "annotation": r.get("annotation", ""),
            "ok": r["ok"],
        } for r in results},
    }
    STANDING_MAP_PATH.write_text(
        json.dumps(map_data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("receipt-standing-lint: map written -> %s" % STANDING_MAP_PATH)

    if args.write:
        from collections import Counter
        applied = Counter()
        for r in failures:
            if "no parseable standing line" not in r.get("reason", ""):
                continue  # never rewrite an existing (unparseable) line's value
            v = apply_backfill(Path(r["file"]))
            applied[v] += 1
        print("receipt-standing-lint: backfilled %d files %s"
              % (sum(applied.values()), dict(applied)))
        return 0

    if args.backfill:
        for r in failures:
            if "no parseable standing line" not in r.get("reason", ""):
                continue
            _, prop = backfill_proposal(Path(r["file"]))
            if prop:
                print("--- backfill proposal for %s" % r["file"])
                print(prop)
            else:
                print("--- no backfill proposal for %s" % r["file"])
        return 0

    for r in failures:
        print("FAIL %s: %s" % (r["file"], r.get("reason", "")), file=sys.stderr)
    if failures:
        print("receipt-standing-lint: %d FAIL" % len(failures), file=sys.stderr)
        return 1
    print("receipt-standing-lint: PASS (0 missing)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
