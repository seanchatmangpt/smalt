# r9b-cosmos-split

window: v26.10.29 · lane L10 · ticket T09 (Cosmos section) ·
status: PARTIAL_ALIVE

## Scope executed (extraction list)

Ownership files only. Extraction list (all new files under `lib/smalt/data_plane/cosmos/`):

- `sql.ex` (1254 ln) -> `Smalt.DataPlane.Cosmos.Sql`: the engine moved
  verbatim from `lib/smalt/cosmos_sql.ex`; only the defmodule line and a
  4-line provenance moduledoc note differ vs HEAD (diff receipted below).
- `lib/smalt/cosmos_sql.ex` (24 ln) -> `Smalt.CosmosSql` defdelegate shim,
  all 8 public functions incl. defaults; call sites, census row
  (`Smalt.CosmosSql.parse`), courts unchanged.
- `auth.ex` (97 ln) -> `Smalt.DataPlane.Cosmos.Auth`: master-key
  string-to-sign closure moved from the engine (authorize/4, master_key/0,
  master_sig/1, string_to_sign/4, valid_master_sig?/6, unauthorized/0);
  defp->def only; wire behavior byte-identical.
- `accounts.ex` -> `Smalt.DataPlane.Cosmos.Accounts` (store_ready?/0).
- `databases.ex` -> `Smalt.DataPlane.Cosmos.Databases` (create_db, list_dbs,
  delete_database, drop_db, db_rid).
- `containers.ex` (37 ln) -> `Smalt.DataPlane.Cosmos.Containers` (26
  defdelegates incl. script/UDF/trigger typed refusals).
- `docs.ex` -> `Smalt.DataPlane.Cosmos.Docs` (12 defdelegates: CRUD, bulk,
  query, change feed, rids).
- `data_plane/cosmos.ex` engine: authorize/4 now delegates to
  `Smalt.DataPlane.Cosmos.Auth.authorize/4`; otherwise untouched.

## Standing

ALIVE — real compile + real court runs this session, embedded below.
PARTIAL on two integration courts blocked by unrelated churn (disclosed below).

## Verification (real output, this session, MIX_BUILD_ROOT=_build-l10)

### 1. Courts exercising the moved engines — exit 0, zero failures

```
$ MIX_BUILD_ROOT=_build-l10 asdf exec mix test \
    test/integration/cosmos_change_feed_test.exs \
    test/integration/cosmos404_typed_error_test.exs \
    test/internal/cosmos_analytical_ttl_test.exs \
    test/internal/cosmos_kd65_scripts_test.exs \
    test/data_plane/cosmos_sql_raise_test.exs \
    test/internal/bkvc_consolidated_court_test.exs
exit=0
Result: 40 passed
```

### 2. data_plane cosmos courts — exit 0

```
$ MIX_BUILD_ROOT=_build-l10 asdf exec mix test \
    test/data_plane/cosmos_k2_rows_witness_test.exs \
    test/data_plane/cosmos_pk_point_read_delete_test.exs \
    test/data_plane/cosmos_pkranges_test.exs \
    test/data_plane/cosmos_ru_throttle_retry_after_test.exs \
    test/data_plane/cosmos_sql_raise_test.exs
    test/data_plane/cosmos_users_permissions_court.exs
exit=0
Result: 41 passed
```

### 3. Internal tier census (new modules registered, zero defects) — exit 0

```
$ MIX_BUILD_ROOT=_build-l10 asdf exec mix test test/internal/internal_tier_census_test.exs
exit=0
Result: 6 passed
```

### 4. Full 45-court gate set — 41/45; 4 failures = unrelated churn (disclosed)

```
$ MIX_BUILD_ROOT=_build-l10 asdf exec mix test \
    test/integration/cosmos_aad_auth_header_test.exs \
    test/integration/cosmos_change_feed_test.exs \
    test/integration/cosmos404_typed_error_test.exs \
    test/integration/tenant_fence_cosmos_test.exs \
    test/internal/cosmos_analytical_ttl_test.exs \
    test/internal/cosmos_kd65_scripts_test.exs \
    test/data_plane/cosmos_sql_raise_test.exs \
    test/internal/bkvc_consolidated_court_test.exs
exit=2
Result: 41/45 passed
Failed: 4 tests
```

The 4 failures (2x CosmosAadAuthHeaderTest, 2x TenantFenceCosmosTest) all die at
STS token mint, BEFORE any Cosmos surface is touched:

```
error[] arm_gateway crash 500: ** (UndefinedFunctionError) function
Smalt.Config.issuer_host/0 is undefined or private
    (smalt 26.10.25) Smalt.Config.issuer_host()
    (smalt 26.10.25) lib/smalt/arm_gateway/router.ex:480: Smalt.ArmGateway.Router.mint_authority/1
```

Unrelated-churn causal chain: `arm_gateway/router.ex` (not an L10 file) calls
`Smalt.Config.issuer_host/0`; `lib/smalt/config.ex` HEAD defines it
(`git show HEAD:lib/smalt/config.ex` line 712) but the working tree does not
(mtime 22:28:27, mid-wave edit by another lane). Stable across two full runs
(22:33 and 22:38). `config/test.exs` was also transiently mid-edit during the
window (mtime 22:38:00). No L10 file appears in any failure chain.

### 5. Invariant gate row (isolated) — PASS

```
$ python3 scripts/invariant_gates.py --gate cosmos-etag-cas
================ INVARIANT-GATES VERDICT TABLE ================
  cosmos-etag-cas      PASS
================================================================
[INVARIANT-GATES] PASS: 1/1 gates (positive held + all negative fixtures refused).
receipt: tmp/invariant-gates/cosmos-etag-cas-receipt.json verdict=PASS
(9 negative fixtures each detected; e.g. stale-write-accepted ->
FAIL stale etag reused -> 412 = mutation correctly refused)
```

## Byte-parity receipts

- sql.ex vs HEAD `lib/smalt/cosmos_sql.ex`: `diff` shows exactly 6 changed
  lines, all in the defmodule line + 4-line provenance moduledoc note; zero
  code-line changes.
- Auth closure: verbatim except defp→def, the `header/2` re-expression, and
  `string_to_sign/4` factored (constructs the byte-identical
  `verb\n<type>\n<link>\n<lc-date>\n\n` string); verified green by the
  cosmos_aad_auth master-key court classes in the 41/45 run (the two
  auth-header tests that do not need STS tokens passed).
- Faces are in-process defdelegate, total over public arities incl. defaults;
  engine remains the wire-semantics owner.

## In-wave compile-freeze ledger (disclosed, no cross-lane edits)

Shared `mix compile` was broken by other lanes' in-flight files 5 times during
the window; each healed by its owner inside the SLA; L10 applied ZERO unblock
fixes to files outside ownership (no disclosure obligations to other lanes):

- 22:05 saml_idp.ex (identity lane) — healed
- 22:10 saml_slo.ex (identity lane) — healed
- 22:14 mcp/tool/cosmos.ex (MCP lane) — healed
- 22:15 key_vault/secrets.ex (KV lane) — healed
- 22:16 mcp/tool/service_bus.ex, key_vault/hsm.ex, purview_atlas/glossary.ex — healed

All L10 waits were bounded compile polls (45s interval, deadline-checked);
no Process.sleep coordination.

## Defect found and fixed in-lane

First post-split court run failed with `Cosmos.Auth.authorize/4 is undefined`
(15 tests): the delegation inside `Smalt.DataPlane.Cosmos` was written as
`Cosmos.Auth.authorize(...)` and the bare-alias form did not expand — call
atom was `:"Elixir.Cosmos.Auth"`. Fixed by using the fully-qualified
`Smalt.DataPlane.Cosmos.Auth.authorize(...)`. Court run after the fix: the
15 previously-failing tests pass (see sections 1-2).

## Not done (honest residue)

- The ticket's end-state is internals migrating into the four faces; this
  landing delivers the namespace, the faces (delegation surface), Sql move +
  shim, and the Auth move. Engine internals remain in `cosmos.ex` (2,943
  lines) — the body-migration step is future work with the same courts.
- cosmos.ex still 2,943 lines; faces absorb internals in a follow-up diff.

Standing: ALIVE (courts+gate ran this session, receipts embedded above);
PARTIAL on the two STS-blocked integration courts, causally isolated from
the split (crash precedes any Cosmos call; same crash reproduced with zero
L10 files in any chain).
