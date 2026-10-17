"""CLI lane fence: docs/ERROR_CODES.md is the generated projection.

Two independent legs (Chicago: real subprocess + real file reads, no mocks):
  1. `python3 scripts/gen_error_codes.py --check` via subprocess — byte-identity
     between the doc on disk and the regenerated projection (exit 0).
  2. Independent literal re-derivation: scan
     smalt_cli/gateway/interceptor.py for the literal ``"code": "MutationRefused"``
     and assert the doc carries a MutationRefused row citing it (the cli-gateway
     surface is a doc source; a doc row without a source literal — or a literal
     without a doc row — fails this fence).

Auto-discovered by GATE1's `tests/test_*.py` glob.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
DOC = REPO / "docs" / "ERROR_CODES.md"
INTERCEPTOR = REPO / "smalt-cli" / "smalt_cli" / "gateway" / "interceptor.py"
GEN = REPO / "scripts" / "gen_error_codes.py"


def test_error_codes_doc_is_byte_identical_projection():
    r = subprocess.run(
        [sys.executable, str(GEN), "--check"],
        capture_output=True, text=True, timeout=60,
    )
    assert r.returncode == 0, r.stdout + r.stderr


def test_mutation_refused_literal_and_doc_row_agree():
    src = INTERCEPTOR.read_text()
    # Independent re-derivation (NOT the generator's regex pipeline): the
    # refusal_envelope body carries a literal error code "MutationRefused".
    m = re.search(r'"code":\s*"([A-Za-z][A-Za-z0-9]*)"', src)
    assert m, "interceptor.py lost its literal error code"
    literal = m.group(1)
    assert literal == "MutationRefused", literal

    doc = DOC.read_text()
    row_re = re.compile(
        r"\|\s*cli-gateway\s*\|\s*(\d{3}|\?)\s*\|\s*MutationRefused\s*\|\s*"
        r"([^|]+?)\s*\|"
    )
    row = row_re.search(doc)
    assert row, (
        "docs/ERROR_CODES.md has no cli-gateway MutationRefused row; "
        "regenerate: python3 scripts/gen_error_codes.py"
    )
    # cite must point at interceptor.py (line number may move with edits)
    assert "interceptor.py:" in row.group(2), row.group(2)


def test_bearer_subcodes_section_matches_bearer_source_literals():
    """The doc's sub-code rows must equal the {:refuse, parent, sub} literals
    re-derived straight from bearer.ex (independent of the generator)."""
    bearer = (REPO / "lib" / "smalt" / "auth" / "bearer.ex").read_text()
    expected = set(
        (p, s) for p, s in re.findall(
            r'\{:refuse,\s*"([A-Za-z][A-Za-z0-9]*)"\s*,\s*"([A-Za-z][A-Za-z0-9]*)"', bearer
        )
    )
    assert expected, "bearer.ex lost its {:refuse, parent, sub} sites"
    doc = DOC.read_text()
    section = doc.split("## Bearer sub-codes", 1)[1]
    found = set(
        (p, s) for p, s in re.findall(
            r"^\|\s*([A-Za-z][A-Za-z0-9]*)\s*\|\s*([A-Za-z][A-Za-z0-9]*)\s*\|",
            section, re.M,
        )
    )
    assert found == expected, (found ^ expected)