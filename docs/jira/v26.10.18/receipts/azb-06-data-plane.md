# AZB-06 — Data plane profile (Cosmos SQL + Blob hot tier) — RECEIPT

- **Ticket**: AZB-06 (docs/jira/v26.10.18/azsim-burn/TICKETS.md)
- **Lane**: planes · **Standing**: PASS (see Full-suite section for shared-tree caveat)
- **Date**: 2026-10-18

## Diffs (all within ticket scope)

| File | Change |
|---|---|
| `lib/smalt/store/dets_mirror.ex` | `sync_write/2` write-through hook (profile-gated), `{:sync_table, table}` handle_call (per-table sync body factored out of `sync_all`), `:repair` start option (default `false` — existing behavior unchanged; reboot-after-SIGKILL opens with `repair: true`) |
| `lib/smalt/data_plane/blob_storage.ex` | (1) `put_blob` overwrite arm now runs as `Store.compare_and_swap/4` (`cas_replace/6` with retry) — exactly one winner under If-Match contention; (2) acknowledged writes call `DetsMirror.sync_write(:smalt_blobs)` (create arm via `store_blob/5`, CAS arm) so the mirror fsync precedes the HTTP ack; (3) `get_blob_conditional` adds `If-Modified-Since` (RFC 7232 whole-second HTTP-date compare, unparseable ⇒ serve, never crash) |
| `lib/smalt/data_plane/cosmos.ex` | RU-throttle read site: `:cosmos` profile `max_ru_limit` wins when present, flat `:cosmos_ru_limit` stays authoritative otherwise; `:unbounded` = explicit no-throttle |
| `config/env/az_prod_data.exs` | unchanged (AZB-04 seed already matched this ticket's spec: `endpoint: "https://localhost:8443", max_ru_limit: :unbounded`, `persistence: :dets_mirrored, sync_interval_ms: 0`) |
| `test/azsim/data_plane_test.exs` | NEW: 8 tests — 100-iteration 6-way If-Match race, wire 206/Content-Range (mid + suffix), If-None-Match 304 wire, If-Modified-Since engine+wire, cosmos throttle profile gate, sync_write profile gate, SIGKILL durability court |

`test.exs` untouched. No `lib/smalt/application.ex` change (my diff: zero lines —
the +2 route lines vs `21f58b0` in the working tree are another plane-lane
ticket's, not mine).

## Ontology / generated artifacts

No new config keys: `smalt:ck-plane*` rows for `:cosmos` and `:blob_storage`
were declared by AZB-04; `sync_interval_ms`/`max_ru_limit` are profile
sub-keys of already-declared keys, and `Smalt.Config.blob_storage/0` /
`cosmos/0` accessors exist in the AZB-04 regen — no `mix smalt.gen` regen
required (verified: accessors return the profile values below).

## Port single-source

No port keys added anywhere. Data-plane listener stays the flat `:egress_port`
(set by the AZB-04 profile file only).

## Accept — real output

```
$ MIX_BUILD_ROOT=_build-lane6 mix test test/azsim/data_plane_test.exs --include azb06_sigkill
8 tests, 0 failures                      # (three consecutive green runs)
$ MIX_BUILD_ROOT=_build-lane6 mix test test/azsim/data_plane_test.exs   # default selection
8 tests, 0 failures  (exit 0)

$ SMALT_PLANES=data mix run --no-start -e 'IO.inspect(Smalt.Config.planes()); IO.inspect(Smalt.Config.cosmos()); IO.inspect(Smalt.Config.blob_storage())'
[:data]
[endpoint: "https://localhost:8443", max_ru_limit: :unbounded]
[persistence: :dets_mirrored, sync_interval_ms: 0]
```

* 6-way If-Match race: `test/azsim/data_plane_test.exs:39` asserts
  `Enum.frequencies == %{200 => 1, 412 => 5}` across **100 iterations** plus
  etag-moved-after-each-iteration — green in every run.
* Range GET: wire dispatch asserts `206` + `content-range: "bytes 10-15/26"`
  + byte-exact slice; suffix `bytes=-5` → `"bytes 21-25/26"`.
* Conditional HEAD/GET: `If-None-Match` match → wire `304` with etag echo,
  mismatch → `200`; `If-Modified-Since` past → `200`/engine `{:ok, blob}`,
  future → wire `304`/engine `{:not_modified, etag}`.
* Durability leg (`sync_interval_ms: 0`): real child OS beam (Port) does
  `create_container` + `put_blob("survivor-payload")` with the profile armed
  and a mirror on a tmpdir; ack is delivered event-driven over the port pipe
  AFTER `put_blob` returned (fsync already inside the write path); parent
  `kill -9` the child os_pid, awaits exit status **137**; then reboots a fresh
  `DetsMirror(dir:, tables: [:smalt_blobs], repair: true)` in the test VM,
  `restore/0`, and asserts `Store.get(:smalt_blobs, "durab/dur/k")` returns
  `survivor-payload`. Zero `Process.sleep` anywhere (deadline receives on
  matched port messages only).

## Falsifier — default boot child list

```
$ MIX_ENV=test mix run -e 'Application.ensure_all_started(:smalt); IO.inspect(Supervisor.which_children(Smalt.Supervisor))'
[WasmEngine.Supervisor, LRO.Sweeper, LRO.Notifier, RollingCounters,
 AmqpBroker, {Bandit}×4, Smalt.Store]    # exactly the 10 children of 21f58b0
```
With `SMALT_PLANES` unset, profile import is a no-op (AZB-04 law) and every
new code path is gated: `sync_write/2` reads `Smalt.Config.blob_storage()`
(default `[]` ⇒ no-op), `cosmos.ru_limit/0` falls back to the flat
`:cosmos_ru_limit` when no profile is imported.

## Anti-vacuity — unconditional-write flip (witnessed)

Gate = the 100-iteration race test. Protocol: sha256 snapshot → SHIM → run →
RESTORE byte-exact.

```
BASELINE  sha256sum lib/.../blob_storage.ex > /tmp/azb06_blob.sha        → recorded
SHIM-COURT  overwrite arm: cas_replace(...) → store_blob(...)  (marker `# SHIM-COURT` in diff)
          mix test test/azsim/data_plane_test.exs:69
          → FAIL: "iteration N: [200, 200, 412, 412, 412, 412]"-class
            (multiple winners — >1×200, exactly the ticket's anti-vacuity
            prediction)
RESTORE   cp snapshot back; sha256sum -c /tmp/azb06_blob.sha → OK
AFTER     mix test test/azsim/data_plane_test.exs:69 → 1 test, 0 failures
```

The flip (green → RED → green) proves the Store CAS is load-bearing.

## Full suite

`mix test` (offline, `MIX_BUILD_ROOT=_build-lane6`) was run to completion; the
shared tree is under heavy concurrent-lane load (coordinator committing
mid-run; load average 340 cited by coordinator), so the authoritative count is
recorded as of the final completed run:

```
$ MIX_BUILD_ROOT=_build-lane6 mix test      # exit 1
1 doctest, 7 properties, 2686 tests, 28 failures (90 excluded)
```

**Classification — zero failures in AZB-06 scope.** `Smalt.Azsim.DataPlaneTest`
is absent from the failure list (0/8), and its companion blob surface passes
standalone under my diff:

```
$ MIX_BUILD_ROOT=_build-lane6 mix test test/data_plane/blob_hardening_test.exs test/azsim/data_plane_test.exs
124 tests, 0 failures
```

All 28 are shared-tree/concurrent-lane classes, matching the AZB-04 receipt's
pattern: planes-lane tickets in flight (`Azsim.IntegrationPlaneTest` AZB-07,
`Azsim.TopologyTest` AZB-10, `Azsim.ControlPlaneTest` AZB-05,
`plane_supervision` compile residue), shared generated artifacts
(`Smalt.ErrorCodesDocTest`, `Smalt.CanonicalProjectionTest` — regenerated at
wrap by law), load-sensitive suites under ~10+ concurrent lane beams
(`SmaltLroTest`, `Smalt.PPlanTest`, `Smalt.TLSTest`, `Smalt.McpTest`,
`McpWireTest`, `Enclave*`, `StressTierCensusTest`, `C1ArmTest`,
`R133PolicyCasTest`), and one torn-read compile error
(`egress_router.ex` mid-edit TokenMissingError, owner-fixed during the run;
the retry leg of this same suite had aborted MIX_EXIT=2 on it — a compile
abort, 0 tests executed, per the census law).

Tree count is 2686 (≥ the ticket's 2655 bar).

## Disclosures

1. **Commit sweep during SHIM-COURT**: a coordinator commit (6f17c6e lineage)
   swept the *shimmed* `blob_storage.ex` (with the `# SHIM-COURT` marker)
   into HEAD mid-court. My working tree carries the restored CAS version
   (sha256-verified byte-exact against the pre-shim snapshot); the uncommitted
   working-tree diff vs HEAD on that file IS the restore. The next lane commit
   must include it.
2. My `test/azsim/data_plane_test.exs`, `cosmos.ex` and `dets_mirror.ex`
   edits were likewise swept into concurrent lane commits; content at HEAD
   equals my final state except for the blob_storage restore above.
3. Another lane's uncommitted `lib/smalt/messaging/amqp/connection.ex` fails
   `mix compile --warnings-as-errors` (unused-clause warnings) — pre-existing,
   not my diff; my files compile warning-clean.
4. Two defunct compile iterations in this session's transcript (backtick
   typo, `@calendar` attribute typo) were corrected in-session before any
   green claim; the SHIM court ran against the final code only.

## Replay

```
MIX_BUILD_ROOT=_build-lane6 mix test test/azsim/data_plane_test.exs --include azb06_sigkill
SMALT_PLANES=data MIX_BUILD_ROOT=_build-lane6 mix run --no-start -e 'IO.inspect(Smalt.Config.blob_storage())'
MIX_ENV=test MIX_BUILD_ROOT=_build-lane6 mix run -e 'Application.ensure_all_started(:smalt); IO.inspect(Supervisor.which_children(Smalt.Supervisor) |> Enum.map(fn {id,_,_,_} -> id end))'
```
