# G1 Queue Storage — Land Receipt (i29)

- **Standing: ALIVE** (surface landed, engine + wire tiers green x2)
Context: pair(egress-lane / G1 queue lane, canonical checkout /Users/sac/smalt, no git commits)
- Date: 2026-10-19

## Subject

Azure Queue Storage REST route family (G1,
`docs/jira/v26.10.18/azsim-burn/G1-QUEUE-STORAGE-SCOPING.md`):
`lib/smalt/data_plane/queue_storage.ex` (577 lines) + egress router arm +
2 StoreTable rows + engine/wire tests.

## What landed

1. **`/Users/sac/smalt/lib/smalt/data_plane/queue_storage.ex`** — pure
   Store-backed engine, `{:ok, status, headers, body}` /
   `{:error, status, code, msg}` tuple contract, coordinator-owned tables
   (`:smalt_q_queues` / `:smalt_q_messages`, never self-created, fail-closed
   `{:error, :store_not_ready}`). Surface:
   - queue lifecycle: create (409 `QueueAlreadyExists` on dup), delete (204 +
     message cascade), list (`comp=list&restype=queue` XML
     EnumerationResults with prefix/marker/maxresults/NextMarker)
   - Put Message (Azure `<QueueMessage>` XML envelope; raw-body fallback),
     64KiB cap (400 `InvalidXmlDocument`)
   - Get Messages (`visibilitytimeout` 0..604800, `numofmessages` 1..32, both
     400 `InvalidQueryParameterValue` out of range), FIFO by construction
     (zero-padded per-queue seq keys on the :ordered_set table, so term order
     IS FIFO), DequeueCount increment, receipt rotation, visibility
     re-appearance (proven by virtual-clock `now_ms` injection — no sleeps)
   - Update/Delete Message with `popreceipt`: stale/superseded/expired
     receipt → 404 `PopReceiptMismatch`; missing message → 404
     `MessageNotFound` (the scoping doc's stale-replay face)
   - typed errors in the blob `x-ms-error-code` JSON envelope style (router
     maps via existing `blob_error/3` + `put_message/2` helpers)
   - `drop_account_data/1` account-teardown cascade (D127 discipline)
2. **Router arm BEFORE the blob splat**
   (`/Users/sac/smalt/lib/smalt/egress_router.ex`):
   a `plug(:queue_storage_plane)` inserted after `maybe_parse_body` and
   BEFORE `plug(:match)`, so it precedes the blob catch-all by construction.
   Disambiguation is query-shape detection exactly per scoping doc section 1:
   `restype=queue` on PUT/DELETE `/{acct}/{queue}`; `comp=list&restype=queue`
   on GET `/{acct}`; `.../messages[/{id}]` path shapes. Everything else
   `:pass` — blob/Cosmos/KV arms see byte-identical requests (pinned by the
   blob-splat-disambiguation wire pin). Wire error rendering reuses the
   existing `blob_error/3` envelope (x-ms-request-id/x-ms-version/
   x-ms-error-code). Files re-checked before each edit
   (`git diff --stat` before = 56 lines azb-20 dirty, after = 228/6 total);
   no mid-edit drift encountered; azb-20 hunks intact.
3. **StoreTables**: two `smalt:StoreTable` individuals added to
   `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`
   (binaryPrefix / owner Smalt.DataPlane.QueueStorage / retention /
   orderedSet, mirroring the sb rows' sweep shape; messages deliberately
   binaryPrefix not tuple because `Store.prefix_keys/2` is the binary-key
   contract used by the cascade deletes), then `mix smalt.gen` regenerated
   `lib/smalt/store_tables.ex` (+22 lines, ONLY the two rows — verified by
   diff). NOT sb_* reuse.
4. **Tests**:
   - `/Users/sac/smalt/test/data_plane/queue_storage_test.exs`
     — 11 engine tests: lifecycle/dup/invalid-name, delete cascade +
     no-resurrection, list prefix/marker/maxresults/400, put XML rendering +
     raw-body, FIFO + default-visibility-hide + virtual-clock re-appearance,
     numofmessages/visibilitytimeout 400s, update rotation + stale replay
     PopReceiptMismatch + MessageNotFound + expired receipt (virtual clock),
     delete-message gone, 64KiB cap.
   - `/Users/sac/smalt/test/wire/egress_wire_test.exs` (+159 lines): 4 wire
     pins over real sockets (lifecycle with x-ms-error-code header pins;
     put/get with receipt rotation; stale-replay 404 PopReceiptMismatch +
     MessageNotFound over the wire; blob-splat disambiguation — plain
     container PUT and blob comp=list pass through untouched).
   - **Fence re-baseline** (lawful per the test's own re-baseline note):
     `test/store_tables_replay_identity_test.exs` — hand-written witness list
     + owned-table census 33→35. Required: the coverage test now scans the
     new atoms; the byte-replay fence passes (render from the pack checkout
     is byte-identical to the regenerated artifact).

## Verification (actual output)

```
$ mix test test/data_plane/queue_storage_test.exs   # run 1
11 tests, 0 failures
$ mix test test/data_plane/queue_storage_test.exs   # run 2
11 tests, 0 failures
$ mix test test/wire/egress_wire_test.exs --include wire   # run 1
26 tests, 0 failures
$ mix test test/wire/egress_wire_test.exs --include wire   # run 2
26 tests, 0 failures
```

Stale-replay face (scoping doc section 2): green at both tiers — engine
(`update: rotates popreceipt, stale replay 404 PopReceiptMismatch, missing
404 MessageNotFound`) and wire (`Queue Storage: stale popreceipt replay
answers 404 PopReceiptMismatch over the wire`).

Regression sweep (session-introduced none):

```
$ mix test test/data_plane/ test/canonical_projection_test.exs
482 tests, 0 failures (2 excluded)
$ mix test test/store_tables_replay_identity_test.exs --include stress
4 tests, 0 failures
```

`mix compile --warnings-as-errors`: no new warnings from the lane's files
(pre-existing ggen_igniter Query.run/2 warning unchanged, unrelated).

## Disclosures / notes

- **Cross-repo pack edit**: ontology rows live in
  `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`
  (designated source of truth per the generated-artifact table in smalt's
  CLAUDE.md; `mix smalt.gen` reads `../ggen-marketplace`). Disclosure for the
  coordinator: ggen-marketplace now carries 2 new StoreTable individuals.
- **Cross-checkout lane file**: `test/e2e/s2_byok/s2_run.patch.py` (untracked,
  another lane's file) untouched.
- The router arm is a plug (`queue_storage_plane`) rather than a route-macro
  arm. Scoping doc allows "an explicit queue-path guard mirroring the
  @blob_get_comps discipline"; the plug form precedes `:match` and therefore
  precedes the blob splat by construction, with zero churn to the azb-20
  lane's in-flight route bodies. Path segments are raw `conn.path_info`
  (not percent-decoded route vars) — consistent with R154 decode-aware
  precedent; percent-encoded queue names are not part of the G1 face.
- Peek/clear-message comps are NOT in the G1 face (scoping doc section 2
  lists put/get/update/delete + lifecycle only). No GAP token minted.
- Pre-existing failure observed on a cold first run only: none — all runs
  green first try after the with-clause/name-length fixes above (fix-forward
  edits are in the receipt's own edit history; the 6→0 failures progression
  is this session's own debug loop, all session-introduced).
- No git actions taken (per task). Receipt paths absolute.
