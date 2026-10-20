# Receipt — W3A (ERRC wave-3, lane W3A): AppConfig snapshots egress routes (W2N fragment)

- **Standing**: PARTIAL_ALIVE (wire-witnessed end to end on an enforce-mode b3 substrate; internal tier has 7 failures, all attributable to other lanes' in-flight files — see Internal tier below)
- **Repo**: /Users/sac/smalt (canonical checkout, no worktrees)
- **Lane ownership**: `lib/smalt/egress_router.ex` (snapshots block ONLY) — honored; one disclosed cross-lane fix under the compile-freeze SLA (below)
- **Build isolation**: `MIX_BUILD_ROOT=_build-lane-w3a`
- **No git operations performed** (coordinator owns transitions)

## Diff

- `lib/smalt/egress_router.ex` (+102, snapshots block only): 6 routes on the KD-53 App Configuration plane — `GET /snapshots`, `PUT /snapshots/:name`, `GET /snapshots/:name`, `GET /snapshots/:name/kv`, `POST /snapshots/:name/archive`, `DELETE /snapshots/:name` — plus `alias Smalt.DataPlane.AppConfigSnapshots` and the egress-owned typed-error mapping (`snapshots_error/2`: 400 InvalidFilter/InvalidComposition, 404 SnapshotNotFound, 409 SnapshotExists/SnapshotNotArchived/SnapshotArchived/Conflict). The block sits BEFORE the blob guarded catch-all family in Plug.Router definition order; a block comment names the PY wf7 MissingXMsVersion witness so the ordering is not "cleaned up".
- `lib/smalt/data_plane/appconfig_snapshots.ex` (+19/-7) — **cross-lane disclosed fix (KD-117 heir class)**: `ensure_table/0` created the table with no heir, so the first creator is a Bandit request task and the table DIES with it — witnessed `PUT /snapshots 201` then `GET /snapshots/:name 404` on the same beam (list also empty). Fix mirrors `Smalt.DataPlane.KeyVaultActions.ensure_deleted_table/0` exactly: `{:heir, Process.whereis(:init), []}` + `rescue ArgumentError`. DISCLOSURE: this file belongs to the wave-2 AppConfigSnapshots lane; the fix is minimal and unblocks the route fragment's witness.

## Witness (real output, enforce mode, lane-private b3 ports 39030..39035, dev config => auth_mode :enforce)

Boot: `MIX_BUILD_ROOT=_build-lane-w3a mix run --no-start -e ... --no-halt` (lock fd closed, `9>&-`), readiness poll on lsof LISTEN. `UP pid=66851`; teardown verified `39030 free`.

Token: `POST http://localhost:39030/oauth2/v2.0/token` (STS, enforce). `token_len=1353`.

```
== 1. seed 3 kv ==
PUT /kv/w3a_a -> 201
PUT /kv/w3a_b -> 201
PUT /kv/other_c -> 201
== 2. PUT snapshot (freeze w3a_* -> 2 items) ==
{"created":1792492818,"etag":"\"6CBC...321B\"","filters":{"composition":"key","filters":[{"key":"w3a_","label":null}]},"item_count":2,...  -> 201
== 3. mutate live kv ==
PUT /kv/w3a_a overwrite -> 200        (value -> "MUTATED")
DELETE /kv/w3a_b -> 204
PUT /kv/w3a_d -> 201
== 4. GET /snapshots/w3asnap/kv frozen ==
{"items":[{..."key":"w3a_a","value":"v-w3a_a"},{..."key":"w3a_b","value":"v-w3a_b"}]} -> 200
```

Freeze proof: the frozen view still shows `v-w3a_a` (NOT "MUTATED"), still contains the deleted `w3a_b`, still has exactly 2 items (new `w3a_d` and `other_c` excluded), etags byte-identical to the pre-mutation etags.

```
== 5. GET snapshot settings + list ==
{"created":...,"item_count":2,"name":"w3asnap","status":"ready"} -> 200
{"items":[... 1 snapshot ...]} -> 200
== 6. typed errors ==
dup PUT            -> 409 SnapshotExists
purge non-archived -> 409 SnapshotNotArchived ("is ready; only archived snapshots can be purged")
== 7. archive ==
POST /snapshots/w3asnap/archive -> 200, "status":"archived"
== 8. kv view after archive ==
-> 409 SnapshotArchived ("kv view is no longer servable")
== 9. purge -> 204; re-purge -> 404; GET after purge -> 404 ==
```

Route-order proof (blob splat does not claim the path): steps 4/5 hit `/snapshots/w3asnap` and received the SNAPSHOT surface's typed errors, never the blob family's MissingXMsVersion.

## Verification

- Compile: `MIX_BUILD_ROOT=_build-lane-w3a mix compile` — CLEAN after wave churn; `--warnings-as-errors` exit 0 (my files contribute zero warnings; shared-tree churn from concurrent lanes blocked several incremental passes — egress_router: 0 error/warning hits in every pass).
- `MIX_BUILD_ROOT=_build-lane-w3a mix test test/internal` (seed 0): **48 tests, 7 failures**. Every failure names other lanes' in-flight files (`deletedkeys_purge_route_test.exs`, `eh_geo_dr_test.exs`, `eh_arm_test.exs`, `sb_topic_fanout_test.exs` census drift + one TLS bad_certificate transport failure in the deletedkeys purge test) — **zero violations cite egress_router or appconfig_snapshots**. Not pre-existing-on-HEAD; introduced by concurrent lanes in this shared tree, owned by those lanes.

## Environment

MIX_ENV dev (enforce), OTP 28.3.1 / Elixir 1.19.5, lane build root `_build-lane-w3a` left for coordinator reclamation (`just lane-clean` at integration).

Context: pair (concurrent ERRC wave-3 lanes active on the same checkout; shared `lib/` churn witnessed throughout).
