#!/usr/bin/env python3
"""POSH invariant gate (G27/G40, v26.10.30): every queries/invariant_*.rq
MUST be empty over the merged T-box+A-box (ontology/posh.ttl +
examples/posh_instance.ttl). Exit 0 clean / 1 typed violation rows /
2 infra (unparseable graph or zero-queries-found loud vacuity) /
3 loud SKIP (pack files not landed). Canonical matrix:
docs/jira/posh/v26.10.30/exit-codes.md"""
import glob
import os
import sys

import rdflib

PACK = os.environ.get("SMALT_POSH_PACK", "ggen-marketplace/packs/posh")
GRAPH_FILES = ["ontology/posh.ttl", "examples/posh_instance.ttl"]

for f in GRAPH_FILES:
    if not os.path.isfile(os.path.join(PACK, f)):
        print(f"[INVARIANT-GATE-SKIP] {os.path.join(PACK, f)} missing — pack not landed; loud skip", file=sys.stderr)
        sys.exit(3)

try:
    g = rdflib.Graph()
    for f in GRAPH_FILES:
        g.parse(os.path.join(PACK, f), format="turtle")
except Exception as e:  # noqa: BLE001 - typed exit 2 infra contract
    print(f"[INVARIANT-GATE-FAIL] cannot parse graph: {e} — re-render with: just posh-generate", file=sys.stderr)
    sys.exit(2)

queries = sorted(glob.glob(os.path.join(PACK, "queries", "invariant_*.rq")))
if not queries:
    print("[INVARIANT-GATE-FAIL] no queries/invariant_*.rq found — vacuous gate", file=sys.stderr)
    sys.exit(2)

failed = False
for q in queries:
    rows = list(g.query(open(q).read()))
    if rows:
        failed = True
        for r in rows:
            print(f"[INVARIANT-VIOLATION] {os.path.basename(q)}: {r}", file=sys.stderr)
if failed:
    sys.exit(1)
print(f"[INVARIANT-GATE] {len(queries)} queries, 0 rows — clean")
