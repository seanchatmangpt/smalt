# D9 — recipe/header docs audit (2026-10-18)
Key finding: docs/reference/just-recipes.md is a STALE PROJECTION (claims "20 modules"; actual 29, 23-30 missing entirely; .venv two-venv claim contradicts ADR-PY-002; _build-lane* claim understates the sweep). Its own header says regenerate — needs a real generator or honest relabel. validate_burn.py header documents exit 2 for IO errors — unimplemented (0/1 only).
Verified accurate: burn defaults, sleep gate, budget gate, quiesce, court-x2, compliance register, lane-cleanup header, W2a rerun note, docs-dod.
