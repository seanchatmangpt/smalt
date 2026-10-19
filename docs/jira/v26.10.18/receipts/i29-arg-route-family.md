# i29 — ARG route family: :sovereign_gap 5.3 un-tag (G6 close)

Standing: PASS — ResourceGraph HTTP route family verified over real HTTP transport (Plug.Test conn through `Smalt.EgressRouter`); test 5.3 un-tagged and green in plain `mix test`.

Context: pair(i29 ARG lane, integration-supervisor lane). The paired lane owned in-flight edits to `lib/smalt/plane/integration_supervisor.ex` and `lib/smalt/store_tables.ex` during my runs; its Store double-start boot freeze was fixed by its owner with a `Process.whereis` guard before my green runs. This lane applied 0 lib/ edits and no cross-lane unblock was needed in the end.

## Subject

- Repo: /Users/sac/smalt, branch main, HEAD 0009df3 working tree. No git operations performed.
- Lane diff (3 files, 0 lib/ files):
  - `test/azsim/sovereign_midnight/sovereign_midnight_test.exs` — `@tag :sovereign_gap` removed from test 5.3 (was line 476).
  - `test/test_helper.exs` — `:sovereign_gap` removed from the ExUnit exclude list; comment updated to CLOSED (v26.10.19) and names this receipt.
  - `docs/TEST_ISOLATION.md` — `:sovereign_gap` row flipped to CLOSED (v26.10.19), closure evidence = this receipt.

## The "landing" is a verification, not a new implementation

Triage (receipts/i29-sovereign-gap-triage.md) classified 5.3 as the one real product gap: `ResourceGraph.query/3` works at module level but the HTTP route family was reported absent (AZB-20 gap-6). On the current tree both halves already exist:

- `lib/smalt/data_plane/resource_graph.ex` — full query engine over `:smalt_resources`: subscription filtering, KQL subset via `Smalt.DataPlane.KQL`, `$skipToken` pagination (TTL'd token table), `resultTruncated` only on the 1000-record server cap, and typed 400s (`InvalidApiVersion`, `InvalidParameter`, `BadQuery`).
- `lib/smalt/egress_router.ex:1311` — `post "/providers/Microsoft.ResourceGraph/resources"`: `with_route` + `with_valid_body`, subscriptions from body, api-version from query string, both `{:ok, status, resp}` and `{:error, status, resp}` arms rendered through the shared JSON renderer, with `x-ms-request-id` / `x-ms-version` headers.

The triage premise was stale against the tree: the route family landed without the tag being retired. No generated registry file was touched by this lane, so no `mix smalt.gen` run was required here (the paired lane regenerates `store_tables.ex` for its own `:smalt_egress_guard` table under its own receipt).

## Verification (real output, verbatim)

1. Pre-un-tag isolated run of the tagged body:

       $ MIX_BUILD_ROOT=_build-ft-arg mix test test/azsim/sovereign_midnight/sovereign_midnight_test.exs --only sovereign_gap
       1 test, 0 failures (17 excluded)

2. Post-un-tag full file, plain run:

       $ MIX_BUILD_ROOT=_build-ft-arg mix test test/azsim/sovereign_midnight/sovereign_midnight_test.exs
       18 tests, 0 failures

3. HTTP-transport witness (mix run script, `:auth_mode` `:anonymous`, real EgressRouter dispatch):

       POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01
       OK-STATUS=200
       BODY=%{"count" => 0, "data" => [], "resultTruncated" => false, "totalRecords" => 0}

       unimplemented operator (`| join kind=fullouter x on $left.id`):
       BAD-STATUS=400
       BAD-BODY={"error":{"code":"BadQuery","message":"unknown pipeline keyword \"join\""}}

   Real HTTP-shaped success (200 ARG envelope) plus a real typed refusal for an
   unimplemented KQL operator — no faked success path.

4. Registry replay identity tests (stress tier, since plain `mix test` excludes them):

       $ MIX_BUILD_ROOT=_build-ft-arg mix test --include stress \
           test/store_tables_replay_identity_test.exs test/smalt_registry_replay_identity_test.exs \
           test/cascade_replay_identity_test.exs test/config_replay_identity_test.exs \
           test/semconv_replay_identity_test.exs
       run 1: 19 tests, 2 failures   ← overlapped the paired lane's concurrent store_tables.ex regeneration
       run 2: 19 tests, 0 failures
       run 3: 19 tests, 0 failures

   The two run-1 failures were not reproducible after the paired lane's regeneration
   settled and are attributed to that concurrency; my lane's diff (2 test files +
   1 doc) cannot affect registry replay. Reported honestly per lane law.

## Residuals

- 5.3's KQL surface is the subset the test exercises (`where` over resource rows);
  unimplemented operators (e.g. `join`) return typed 400 `BadQuery` — verified above.
- The 3.1 Service Bus lock-lost 1-in-4 flake from the triage receipt is untouched
  by this lane and remains filed for root-cause in the paired lane's scope.
