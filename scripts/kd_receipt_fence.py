#!/usr/bin/env python3
"""KD register receipt-path fence (KD-DOD, v26.10.22).

Extracts receipt paths from KD register rows (`| KD-nn | ...` table cells in
every KNOWN_DIVERGENCES.md under docs/jira/) and verifies each cited path
exists on disk. Fail-closed: any missing receipt exits 1 naming the row id
and path. Phantom evidence cites inside KD tables are exactly the defect
class docs-dod-check did not cover before this fence (KD-MIRROR finding).

A path starting with `docs/` is relative to the repo root; a bare
`receipts/...` path is relative to the register's own directory.
"""
import re
import sys
from pathlib import Path

RECEIPT_RE = re.compile(
    r"(?<![\w./-])(?:(?:docs/jira/v[0-9][0-9.]*)?/)?receipts/[A-Za-z0-9._/-]+\.md"
)
ROW_RE = re.compile(r"^\|\s*(KD-[0-9]+)\b")
# A cite the row itself declares not-yet-landed ("(in-flight, BK-nnn)") is a
# loud SKIP, not a MISS: the row admits the receipt does not exist yet.
INFLIGHT_RE = re.compile(r"\(in-flight")


def registers(root: Path):
    for p in sorted(root.glob("docs/jira/*/KNOWN_DIVERGENCES.md")):
        yield p


def pattern_docs(root: Path):
    """Milestone pattern docs (BK-DODSUB): patterns/ subdir + root-level
    BROWSER-COURT-PATTERNS.md cite receipts the KD fence must cover too."""
    yield from sorted(root.glob("docs/jira/*/patterns/*.md"))
    yield from sorted(root.glob("docs/jira/*/BROWSER-COURT-PATTERNS.md"))


# BK-CITEG (v26.10.22): milestone PRD/VALIDATION/FINAL-RELEASE docs cite
# receipt + evidence paths under a DUAL-BASE convention (milestone-relative
# bare paths and repo-root paths both occur). Seal docs also cite EXPECTED
# receipts for in-flight/pending work; a gap the row itself types
# (IN-FLIGHT / QUEUED / PENDING-GATE / "expected receipt" / "not on disk" /
# "absent") is a loud SKIP, not a MISS — same convention as the KD
# (in-flight) skip above. Witnessed: BK-ARD21B (2 non-resolving PRD cites),
# BK-10b (6 typed-expected FINAL-RELEASE cites).
SEAL_DOCS = [
    "docs/jira/v26.10.21/PRD.md",
    "docs/jira/v26.10.21/VALIDATION.md",
    "docs/jira/v26.10.22/PRD.md",
    "docs/jira/v26.10.22/VALIDATION.md",
    "docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md",
]
SEAL_GAP_MARKERS = (
    "IN-FLIGHT", "QUEUED", "PENDING-GATE",
    "expected receipt", "not on disk", "absent",
)


def milestone_docs(root: Path):
    for rel in SEAL_DOCS:
        p = root / rel
        if p.exists():
            yield p


def check_milestone_docs(root: Path):
    """Dual-base citation check over milestone PRD/VALIDATION/FINAL-RELEASE
    docs. A bare path resolves against the doc's own milestone directory
    first, then the repo root; a `docs/`-prefixed path resolves against the
    repo root. Returns (checked, misses, skips)."""
    checked = misses = skips = 0
    for doc in milestone_docs(root):
        doc_dir = doc.parent
        for i, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
            typed_gap = any(m in line for m in SEAL_GAP_MARKERS)
            for path in RECEIPT_RE.findall(line):
                checked += 1
                p = Path(path)
                if path.startswith("docs/"):
                    full = root / p
                elif (doc_dir / p).exists():
                    full = doc_dir / p
                else:
                    full = root / p
                if full.exists():
                    continue
                if typed_gap:
                    print(f"SKIP  {doc.relative_to(root)}:{i}  {path}  "
                          f"(typed gap on the citing line)")
                    skips += 1
                else:
                    print(f"MISS  {doc.relative_to(root)}:{i}  {path}")
                    misses += 1
    return checked, misses, skips


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    rc = 0
    checked = 0
    for reg in registers(root):
        text = reg.read_text(encoding="utf-8")
        reg_dir = reg.parent
        for line in text.splitlines():
            m = ROW_RE.match(line)
            if not m:
                continue
            row_id = m.group(1)
            if INFLIGHT_RE.search(line):
                print(f"SKIP  {row_id}  {reg.relative_to(root)}: "
                      f"cite declared (in-flight) by the row itself")
                continue
            for path in RECEIPT_RE.findall(line):
                p = Path(path)
                full = (root / p) if path.startswith("docs/") else (reg_dir / p)
                checked += 1
                if not full.exists():
                    print(f"MISS  {row_id}  {reg.relative_to(root)}: {path}")
                    rc = 1
    for doc in pattern_docs(root):
        # Bare cites in a patterns/ subdir are milestone-root-relative
        # (same convention as KNOWN_DIVERGENCES.md), not subdir-relative.
        doc_dir = doc.parent if doc.parent.name != "patterns" else doc.parent.parent
        for line in doc.read_text(encoding="utf-8").splitlines():
            for path in RECEIPT_RE.findall(line):
                p = Path(path)
                full = (root / p) if path.startswith("docs/") else (doc_dir / p)
                checked += 1
                if not full.exists():
                    print(f"MISS  {doc.relative_to(root)}: {path}")
                    rc = 1
    m_checked, m_misses, m_skips = check_milestone_docs(root)
    checked += m_checked
    if m_misses:
        rc = 1
    print(f"kd-receipt-fence: checked {checked} receipt cites "
          f"across {len(list(registers(root)))} registers + "
          f"{len(list(pattern_docs(root)))} pattern docs + "
          f"{len(SEAL_DOCS)} milestone docs "
          f"({m_checked} cites, {m_skips} typed-gap skips) -> "
          f"{'FAIL' if rc else 'OK'}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
