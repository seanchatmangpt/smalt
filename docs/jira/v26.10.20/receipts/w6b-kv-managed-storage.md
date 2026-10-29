# w6b — Key Vault managed storage account faces

**Standing:** PARTIAL_ALIVE (module + witness ALIVE; route mount HELD on the
egress_router.ex compile-limit freeze — faces are module-direct reachable,
routes pending the structural-split lane)

## Landed
- `lib/smalt/data_plane/kv_managed_storage.ex` (NEW, exclusive lane file):
  2016-10-01 KV managed-storage surface — create (atomic 409
  ManagedStorageAccountNameAlreadyExists via ONE `:ets.insert_new`), get,
  list, soft delete (deleted bundle with recoveryId/deletedDate/
  scheduledPurgeDate), list_deleted, get_deleted, recover, purge (204),
  keys, regenerate (fresh material on the active key + flip to the other
  key; `autoRegenerateKey: false` -> typed 400
  `ManagedStorageAccountNotRegenerated`), SAS definitions (put 201 / get /
  list / delete 204, atomic 409, typed 404 SasDefinitionNotFound).
  Shadow-table law: module-owned heir'd `:smalt_vault_managed_storage`
  (`heir: Process.whereis(:init)` 3-tuple), ArgumentError rescue keeps the
  create race fail-safe.
- `tmp/w6b_witness.exs` + `tmp/w6b_witness.out` — real-output witness.

## Verification (real output)
- Strict compile: `mix compile --warnings-as-errors` — 0 warnings in the
  module (forced recompile check: grep count 0), `Generated smalt app`,
  RC=0.
- Witness (`mix run --no-start tmp/w6b_witness.exs`, real Smalt.Store,
  no mocks, no sleeps — bounded monitor-DOWN receive): EXIT=0, 11 face
  groups all OK:
  TABLE_PERMANENCE_OK / CREATE_OK / DUP_409_OK / BAD_BODY_400_OK / GET_OK /
  LIST_OK / REGEN_OK / DELETE_RECOVER_OK / PURGE_OK / SAS_OK /
  `W6B WITNESS: ALL FACES OK`.
- Witness was exercised in an isolated `git archive` scratch materialization
  (`git archive HEAD` + module copy, no worktree, doctrine-compliant) because
  the shared tree had continuous neighbor-lane compile churn; module and
  witness synced back to the canonical checkout byte-identical.

## Deferred (coordinator HOLD)
- `lib/smalt/egress_router.ex` route mount (10 routes, `/managedstorage*`)
  — HELD per coordinator 2026-10-20: the module crossed the BEAM compiler
  implementation limit; the structural-split lane owns the mount. Faces are
  fully witnessable module-direct; the mount is additive when it lands.

## Disclosures
- Compile-freeze SLA unblock fix (minimal, disclosed): removed one stray
  in-flight line in `lib/smalt/data_plane/certificates.ex` (`case
  conn_or_host for host extraction`) that was freezing strict compile for
  every lane; owner's intent preserved (the correct `case` was on the next
  line).
- Lane build root `_build-lane-w6b` + witness scratch tree under /tmp left
  for coordinator `just lane-clean`.
