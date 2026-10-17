# I11 — cli-test leg 2 interpreter fix (ADR-PY-002 fallback)

Standing: PARTIAL_ALIVE (fix landed and witnessed; 2 pre-existing failures in leg 1 reported, not session-introduced)

Lane: I11, lease `smalt-cli/`. Date: 2026-10-17.

## Change

`justfile.d/03-cli-wiring.just`: `VENV` pointed at `smalt-cli/.venv/bin/python`,
which does not exist (only `.venv-cli` exists). Read `smalt-cli/GATES.md` +
`smalt_cli/gates.py` first: ADR-PY-002's per-lane layout `.venvs/<lane>` does
not exist; `resolve_venv` (gates.py:144) falls back to the documented
`FALLBACK_VENV = .venv-cli` with a loud `venv_note`. Consistent with that
in-tree diff, `VENV` now resolves to `.venv-cli/bin/python` (no `.venv`
symlink minted — gates.py never consults a bare `.venv`, an alias would be
untracked ambiguity). Stale header/echo comments updated. Diff is
interpreter-path only; no recipe logic touched.

## Commands + output

Leg 1 (unchanged interpreter, already `.venv-cli`):

```
just cli-test
...
FAILED tests/test_cosmos.py::test_whitelist_refuses_non_star_queries_400[SELECT c.id FROM c]
FAILED tests/test_cosmos.py::test_whitelist_refuses_non_star_queries_400[SELECT * FROM c WHERE c.n = 2]
2 failed, 45 passed, 2 skipped, 6 warnings in 71.47s
```

Leg 2 (the fixed leg):

```
cd smalt-cli && .venv-cli/bin/python -m pytest smalt_cli/ -q -p no:cacheprovider
102 passed, 6 warnings in 96.49s (0:01:36)
```

Leg 1 skip inventory (`-rs`, second run 48.96s): both skips typed and loud —
`SKIP-KD19` (EH $management -> 501, OPEN KD-19) and `SKIP-KD77-RESIDUAL`
(batch-delete partial-list survivor premise rot; delivery-tag fix receipted).
The expected intentional loud skip (SKIP-KD77-RESIDUAL) is present; SKIP-KD19
additionally skips, also typed/registered.

## Pre-existing failures (not mine, diagnosed)

`tests/test_cosmos.py::test_whitelist_refuses_non_star_queries_400` (2
params) expects 400 for non-`SELECT * FROM c` queries. The emulator landed a
real SQL capability: `lib/smalt/data_plane/cosmos.ex:1331-1363` keeps the
`SELECT * FROM c` fast path but parses every other query with
`Smalt.CosmosSql` (WHERE/ORDER BY/LIMIT/IN/CONTAINS/@params) and answers it —
only grammar-external queries get 400. The test premise is stale against a
landed capability (premise rot, testing-chicago-style "test premises rot when
the substrate gains a capability"). `SELECT * FROM c WHERE c.n = 2` parses
clean under the new grammar, so nothing raises. Pre-existing: `cosmos.ex` has
no in-flight diff (`git diff HEAD -- lib/smalt/data_plane/cosmos.ex` empty);
test_cosmos.py last touched at b88c8b5. Not fixed here — outside this lane's
task scope; flag for the owner of the CosmosSql lane to rewrite the premise
(or register a KD row).

## Suggested fix for the owner (not applied)

Rewrite `test_whitelist_refuses_non_star_queries_400` into a split premise:
- trivial `SELECT * FROM c` fast path still 200;
- `SELECT c.id FROM c` / `SELECT * FROM c WHERE c.n = 2` now 200 with real
  evaluated results (assert WHERE actually filters);
- 400 only for grammar-external forms (e.g. `TOP`, joins, ` CosmosDB`).

## Falsifier / replay

```
git diff justfile.d/03-cli-wiring.just   # VENV -> .venv-cli, comments only
cd smalt-cli && .venv-cli/bin/python -m pytest smalt_cli/ -q -p no:cacheprovider
```

## Follow-up (2026-10-17, cosmos test lane): split-premise rewrite applied

The 2 pre-existing failures flagged above are fixed. `tests/test_cosmos.py`
`test_whitelist_refuses_non_star_queries_400` split into:

- `test_whitelist_refuses_grammar_external_queries_400` — params outside the
  CosmosSql grammar (joins/TOP/OFFSET class: `SELECT VALUE c.n FROM c`,
  ` CosmosDB`, `SELECT * FROM c OFFSET 1 LIMIT 1`) still expect typed 400.
- `test_cosmos_sql_evaluates_non_star_queries_200` — valid non-star queries
  (`SELECT * FROM c WHERE c.n = 2` filtered to the matching doc;
  `SELECT c.id FROM c` projection returns both seeded docs) expect 200 with
  real evaluated results.

Two-venv shape preserved (`.venv-cli`); lane fixture booted its private-port
substrate per conftest session protocol. Replay:

```
cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_cosmos.py -q -p no:cacheprovider
8 passed in 17.96s
```
