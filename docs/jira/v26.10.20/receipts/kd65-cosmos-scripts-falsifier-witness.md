# KD-65 witness — Cosmos script resources + trigger-header fence (lane K8)

**Standing:** **ALIVE** (fix landed, falsifier green on real engine+store)

- Lane: K8 (divergence-finish tail rows), v26.10.20 window
- Surface: `lib/smalt/data_plane/cosmos.ex` (KD-65). The w6f/w6g routes in
  `lib/smalt/egress/CosmosRoutes.ex` (untouched) already existed but called
  engine functions that did not exist anywhere in lib/.
- KD row: canonical v26.10.14 register `KNOWN_DIVERGENCES.md:240` (KD-65, OPEN)

## What was wrong (witnessed live 2026-10-20, substrate pid 57559, ports 8443/9443)

1. **All 14 script-resource faces were 500 with an empty body.** The w6f/w6g
   routes in `CosmosRoutes.ex` call `Cosmos.list_sprocs/create_sproc/execute_sproc/
   get_sproc/replace_sproc/delete_sproc/put_udf/get_udf/delete_udf/list_udfs/
   put_trigger/get_trigger/delete_trigger/list_triggers` — none of these functions
   existed anywhere in `lib/` (grep across lib/ returned zero defs). Every route
   answered `UndefinedFunctionError` → empty 500:
   - `PUT /dbs/kd65db/colls/c1/sprocs/sp1` → ` [500]` (empty body)
   - `POST .../sprocs/sp1` (execute) → ` [500]`
   - `PUT .../triggers/t1` → ` [500]`
2. **Trigger headers on doc create were a silent 201** (the row's exact
   divergence): `POST .../docs` with `x-ms-documentdb-pre-trigger-include: t1`
   → **201**, doc stored, no script executed (curl witness above).

## Fix (surgical, `# KD-COVERS: KD-65` carried in lib/)

`lib/smalt/data_plane/cosmos.ex`:
- 14 public script-resource functions added, each answering a typed
  Cosmos-envelope `501 NotImplemented` naming the face and stating "nothing was
  stored" (JS evaluation out of scope — exactly the registered close condition:
  "typed Cosmos-coded refusal for sproc routes").
- Trigger-header fence: `x-ms-documentdb-(pre|post)-trigger-(include|exclude)`
  present on doc create (`do_create_doc/4`) or replace (`do_put_doc/5`) → typed
  `501 NotImplemented` naming the header, **never a silent 201**. PATCH/Delete
  faces are 80/20-out (real Cosmos triggers apply to create/replace/delete;
  delete + patch legs left as-is and named in this receipt as remaining
  80/20 residue).

## Falsifier (row close condition) — executed, PASS

`MIX_BUILD_ROOT=_build-k8 mix test test/internal/cosmos_kd65_scripts_test.exs`:

```
....
Finished in 0.05 seconds (0.00s async, 0.05s sync)
4 tests, 0 failures
```

- scripts.create → typed 501 refusal ✓ (all 13 single faces + 3 list faces asserted 501)
- create with pre-trigger-include → typed 501, doc feed empty afterwards (nothing stored) ✓
- replace with post-trigger header → typed 501 ✓
- control: create/replace without trigger headers still 201/200 (no over-refusal) ✓

Regression: `mix test test/data_plane` → 48 tests, 1 failure —
`DataPlane.CosmosSqlRaiseTest "unknown fn in projection"` (cosmos_sql.ex
surface; my lane touched no cosmos_sql code — file was already modified by
another lane at session start, failure class unrelated to the KD-65 fence).
All other 47 data_plane tests green, including the cosmos pkranges/doc suites
exercising create/put paths around the fence.

## FLIP-ELIGIBLE

Close condition met per the row's own terms (typed refusal + falsifier green).
Flip `KNOWN_DIVERGENCES.md` (canonical v26.10.14) via `scripts/kd_flip.py --apply`
gated on this receipt mtime postdating the cosmos.ex shim mtime.
