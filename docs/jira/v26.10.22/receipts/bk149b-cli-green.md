# BK-149b — smalt-cli green (pyright loose ends + premise-rot test repairs)

**Standing:** **ALIVE** — all BK-149-flagged pyright defects repaired; touched files
pyright-clean (0 errors); full smalt-cli suite runs with 0 failures attributable
to this lane (1 residual failure is concurrent-lane drift, disclosed below).

Context: solo

Lane: bk149b, 2026-10-22, repo /Users/sac/smalt, venv `.venv-cli`.

## Flag re-audit (stale vs real)

The dispatch list contained stale premise — several flags were already fixed:

| Flag | Verdict |
|---|---|
| test_ty_keyvault.py `conftest.ANON_EGRESS`/`ANON_ARM` missing | STALE — conftest defines them; test passes |
| test_ty_keyvault.py `json` undefined at :82 | STALE — `__import__("json")` idiom, pyright-clean |
| keyvault.py `wire` symbol missing | STALE — `from .. import wire` present; 12/12 ty_* probes pass against live substrate |
| deployment.py non-total return + `proc` possibly unbound | REAL — fixed |
| servicebus.py `ServiceBusClient` possibly unbound | REAL — fixed |
| test_ty_deployment.py `TMPL_PATH` undefined | REAL — fixed |
| test_blob.py/test_cosmos.py failures | REAL — premise rot vs KD-135/cosmos_sql capability landings |

## Fixes

1. `smalt_cli/wire.py` — `andon()` retyped `-> NoReturn` (it always raises
   `typer.Exit(1)`). Resolves `proc`/`ServiceBusClient` possibly-unbound and the
   non-total return in deployment.py/servicebus.py at the type layer, without
   restructuring. Also made `emit`'s receipt branch defensive for 1-tuple rows
   from `_tabular` (`row[1] if len(row) > 1 else ""`) — fixes a real latent
   IndexError for scalar-list payloads printed as `--output receipt`.
2. `tests/test_ty_deployment.py` — `TMPL_PATH` is now a real module global
   (`TMPL_PATH = ""` + `global TMPL_PATH` in the `_env` autouse fixture)
   instead of the pyright-invisible `globals()["TMPL_PATH"]` minting.
3. `tests/test_cosmos.py` — premise-rot repair: the whitelist-400 param case
   `SELECT * FROM c OFFSET 1 LIMIT 1` is now ADMITTED by Smalt.CosmosSql
   (OFFSET <n> LIMIT <m> pair form, cosmos_sql.ex:962). Moved to a new
   `test_offset_limit_pair_admitted_200` asserting 200 with exactly 1 row over
   2 seeded docs. Also `create_container(partition_key=PartitionKey(path="/pk"))`
   for SDK-typing parity.
4. `tests/test_blob.py` — KD-135 premise rot: default containers are WRITABLE
   (wire parity, blob_storage.ex:178-180); the WORM-overwrite leg now opts in
   explicitly via `make_immutable_container` (`x-ms-immutable-policy: true`)
   and still asserts 409 `ContainerLocked`. Also a `getattr(e.response,
   "headers", {})` typing guard on the error-code probe.
   DISCLOSURE (compile-freeze class): test_blob.py and test_cosmos.py were
   concurrently edited by another lane while this leg ran; this leg's one-line
   WORM fix was applied on top of the on-disk state, which is what was tested.

## Verification

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_ty_*.py -q
12 passed in 121.29s

$ .venv-cli/bin/python -m pytest tests/ -q -p no:cacheprovider
1 failed, 128 passed, 2 skipped, 6 warnings in 74.27s

$ .venv-cli/bin/python -m pytest tests/test_blob.py tests/test_cosmos.py tests/test_ty_deployment.py -q
17 passed in 19.71s

$ pyright smalt_cli/wire.py tests/test_ty_deployment.py tests/test_cosmos.py tests/test_blob.py
0 errors, 0 warnings, 0 informations
```

Whole-repo pyright went 94 -> 81 errors before this lane scoped to touched
files; remaining errors are in files this lane does not own (test_resourcegraph,
test_servicebus, test_w3_session_ops SDK-typing strictness) — pre-existing.

## Residual (not this lane's diff)

`tests/test_error_codes_doc.py::test_error_codes_doc_is_byte_identical_projection`
fails because `scripts/gen_error_codes.py` regenerates docs/ERROR_CODES.md with
2 new rows (InvalidCloudEvent, InvalidEventGridEvent) projected from the
CONCURRENT lane's in-flight `lib/smalt/egress_router.ex` edit
(egress_router.ex:3542/:3634 in the shared tree). This lane's diff contains no
lib/ files; the drift is theirs to regenerate at integration. Skip-census
fluctuation (2 vs 10 skips) tracks 9443-substrate availability under
concurrent-lane lock contention — all skips are loud and typed (SKIP-KD19,
SKIP-KD77-RESIDUAL, migrate-leg LOUD SKIPs), never silent.
