# W-6 Receipt — Cosmos Change Feed (GAP-AUD1-04) + RFC 6902 Patch (GAP-AUD1-05)

Lane W-6, repo /Users/sac/smalt, branch main @ fd9cfea (workdir, uncommitted per dispatch).

## Subject

- `lib/smalt/data_plane/cosmos.ex` — change feed + RFC 6902 patch engine
- `lib/smalt/egress_router.ex` — PATCH route + op-list unwrap
- `test/data_plane/cosmos_test.exs` — 9 falsifier tests (W-6 describes)
- `docs/audit/sections/aud1-blob-cosmos.md` — GAP-AUD1-04/05 → CLOSED-WITH-RECEIPT
- `docs/jira/v26.10.14/receipts/w6-feed-patch.md` — this receipt

## Implementation

### GAP-AUD1-04 — Change Feed

- `change_feed/3` + `list_docs` A-IM detection (`cf_requested?` on the
  `a-im` header, case-insensitive "incremental feed"). Without the header,
  `do_list_docs` is byte-for-byte the prior behavior.
- Per-container session cursor persisted in the store-owned `:smalt_cosmos_pk_meta`
  table under tuple key `{2, db, coll}` (tuple keys sort above every binary, so
  the cursor is invisible to `Store.list_prefix/2` binary scans — same trick as
  the `{0, db}` / `{1, db, coll}` meta records).
- Cursor = `%{"ts" => max delivered _ts, "seen" => %{id => _etag}}` pinned at
  the boundary second. A doc is new when `_ts` > cursor ts, OR `_ts == ts` and
  its CURRENT `_etag` differs from the pinned one — so a same-second UPDATE
  re-surfaces exactly once and a same-second create is delivered exactly once
  despite `_ts` resolution of 1s.
- Every response emits `x-ms-continuation` = base64url("cf<ts>:<n>"); without
  the A-IM header the response shape is the prior one, unchanged.
- Store.clear() resets the cursor with the tables (tests are deterministic).

### GAP-AUD1-05 — RFC 6902 Patch

- Router `patch "/dbs/:db/colls/:coll/docs/:doc_id"`: unwraps the Plug.Parsers
  `%{"_json" => list}` wrapper, refuses non-array bodies 400 BEFORE the engine
  (PATCH is a separate route, never the SQL query path).
- Engine `patch_doc/5` gated like every other doc surface (master-key auth +
  RU throttle + consistency echo), then:
  - 404 NotFound on missing doc; invalid route doc-id → 404 (doc_id_check)
  - RFC 6902 engine: add / remove / replace / test / move / copy over RFC 6901
    JSON pointers (~0/~1 unescape, "-" append on arrays, root add replaces the
    doc; root remove refused — the store holds whole docs)
  - typed 400 BadRequest on malformed ops; 400 BadRequest on failed `test`
    (stored doc untouched — apply runs on an immutable copy)
  - If-Match: etag check + write as ONE `Store.compare_and_swap/4` (the S8
    atomicity guarantee — 412 on mismatch AND on same-doc race)
  - success = 200 + full-document re-storage with fresh `_etag`/`_ts`, LSN
    bumped, `etag` response header

## Verification (real output)

- `mix compile` → clean (see Deviations for the shared-tree state during the wave)
- `mix test test/data_plane/cosmos_test.exs` → `114 tests, 0 failures`
  (105 pre-existing + 9 new W-6 tests, all green)

Falsifier tests landed (test/data_plane/cosmos_test.exs, describes
"W-6 change feed" / "W-6 RFC 6902 patch"):

1. change feed full read: all docs + continuation emitted
2. change feed incremental: new-only after cursor; drain → 0; update re-surfaces once; drain → 0
3. list without A-IM unchanged and does not advance the cursor
4. A-IM via `list_docs` routes to the change feed
5. patch round-trip via the ROUTER (add/replace/remove/test/copy/move, array
   insert-at-0, JSON-patch content type, full re-storage verified by re-read)
6. etag precondition: If-Match mismatch 412, match 200 with new etag (CAS)
7. missing doc 404
8. malformed patch typed 400 — 7 malformed corpora + router non-array 400
9. failed `test` op 400 with stored doc untouched

## Witnesses

- change-feed incrementality: feed2 `["new"]`, feed3 `_count == 0`, feed4
  `["old"]` (update), feed5 `_count == 0` — delivered-once + update-once.
- patch round-trip: router PATCH 200 → age=42, name="n2", tags=["x"],
  moved="n2", copy removed, `_etag` present; GET re-read confirms storage.

## Deviations / disclosures

1. Compile-freeze SLA unblock (disclosed per rule): during the wave the shared
   `lib/smalt/egress_router.ex` was mid-edit by the W-8 (GAP-AUD1-02) lane —
   their block landed inside the `{:error, :expired}` clause's `send_json`
   map literal, breaking the file compile. I applied a minimal completion of
   the interrupted map literal (AuthorizationFailure 403 body: code + message).
   W-8 subsequently landed the rest of their block (batch helpers) and the
   tree compiles clean; final compile is the receipt's `mix compile` above.
2. Test-failure semantics: a failed RFC 6902 `test` op answers 400 BadRequest
   ("A test operation of the patch failed."), not 412 — 412 is reserved for
   the If-Match precondition per the work order; real Cosmos does not
   document a distinct test-failure status.
3. The change-feed cursor lives per container (single hash range), so
   "per-partition" reduces to per-container in this engine — the pk_meta
   table storage site is as specified.

## Re-verification (R46, 2026-10-15)

- `MIX_BUILD_ROOT=_build-lane51 mix test test/data_plane/cosmos_test.exs` →
  `120 tests, 0 failures` (count moved 114 → 120 since the original receipt;
  current count cited per repair dispatch, history above unaltered).

Standing: ALIVE
