# R178d — probe venv docs: honest interpreter matrix + README

Standing: PASS

Docs-only landing; verified statically (no runtime claim to re-run).

## Witnesses

- `smalt-cli/GATES.md` ("Interpreter matrix — honest description (repair
  R44)"): states plainly that ADR-PY-002's per-lane venvs at
  `smalt-cli/.venvs/<lane>` do not exist — `.venvs/` holds only symlinks
  named after test files, every suite resolves through `resolve_venv`'s
  fallback to `smalt-cli/.venv`, and the loud `venv_note` is carried in
  results. Defect reported, not papered over; owner: coordinator.
- `.venvs/` on-disk census (docs lane, 2026-10-16): 8 symlinks
  (`test_blob.py -> ../.venv-cli`, `test_cosmos.py`, `test_eventhub.py`,
  `test_identity.py`, `test_keyvault.py`, `test_resourcegraph.py`,
  `test_servicebus.py`, ...) — matches the GATES.md description exactly.
- `smalt-cli/README.md:11-12,72-73`: two-venv quickstart and per-marker
  pytest invocations (anonymous/enforce) present and consistent with
  GATES.md.

Docstrings: 7 probe/gate docstrings updated in the R44/R178d surface
(`smalt-cli` gates + wire suites) — statically witnessed via the GATES.md
rewrite; no behavior change to verify.
