# Receipt — V261014-19 Egress Security & Envelope Correctness Sweep

- **Lane:** 19 · **Date:** 2026-10-15 · **Status:** ALIVE (items 1-7 landed and fenced; suites green except pre-existing failures disclosed below)
- **Subject:** /Users/sac/smalt @ working tree (no git state changes, per lane rules)

## Pre-check (Item 1, required grep)

`grep -rn "x-ms-request-id" test/security test/data_plane` (2026-10-15, re-run at
implementation time): blob-plane pins only (`blob_hardening_test.exs` x3,
`blob_service_test.exs` x2, plus a comment in `audit_planes_test.exs`). **No test
pins the header-emitting 200 on the SKR release route.** No pin updated; nothing
changed silently.

## Landed

### Item 1 — SKR release blob-header leak (lib/smalt/egress_router.ex)
Both arms of `post "/keys/:name/release"` now render through `send_json/3`
(was `blob_error/3`, which stamps `x-ms-request-id` + `x-ms-version` on the KV
200 — F5 law violation). 200s and error envelopes are blob-header-free.

Fences (test/egress_dispatch_test.exs):
- "lane 19 item 1: SKR release 200 carries no blob-plane headers" — asserts
  `x-ms-request-id`/`x-ms-version` **absent** from the 200, body unchanged.
- "lane 19 item 1b: SKR release error envelope also stays blob-header-free" —
  404 path, headers asserted absent.

### Item 2 — Sentinel `:dcr_created` marker never produced by lib (sentinel.ex)
`do_ingest/3` now writes `Store.put(:smalt_sentinel_streams, {:dcr_created, dcr}, true)`
after the stream put (idempotent). The `:sentinel_dcr_strict` fence now pivots
on state the lib itself creates.

Fences (test/data_plane/audit_planes_test.exs, "lane-19 egress-security fence"):
- strict mode admits a DCR the lib created, then queries back by dcr (2 rows);
- strict mode still refuses a truly never-created DCR (404 DCRNotFound).

### Item 3 — ResourceGraph unvalidated subscriptions shape (resource_graph.ex)
`query/3` validates `subscriptions` before dispatch: `nil` and all-binary lists
admitted; string/map/mixed shapes answer
`{:error, 400, InvalidParameter}` — never 500, never silent all-resources.

Fences (test/egress_dispatch_test.exs): `"subscriptions": "sub-1"` and
`{"a": 1}` → 400 InvalidParameter; list shape still 200 (regression arm).

### Item 4 — `:smalt_resource_graph_tokens` unbounded (resource_graph.ex)
Implemented the preferred cap+TTL: every mint sweeps entries older than
`@token_ttl_ms` (15 min) and evicts oldest-created-first while the table
exceeds `@token_cap` (1000); expired/evicted tokens take the existing
unknown-token path. Moduledoc documents the bounds.

Fences (audit_planes_test.exs): expired token swept on next mint (assert
`:error` on the expired key, minted token present); cap eviction (1000 seeded
aged tokens + 1 mint → oldest gone, table held at 1000).

### Item 5 — `get "/keys"` catch-all crash (egress_router.ex)
Replaced the `elem/2` catch-all with explicit `{:ok, s, b}` plus a guarded
3-tuple arm and a final fallback answering a typed 500 envelope
(`Logger.error` + `InternalError`) — total arms, no unhandled raise. Note: an
`{:error, _, _}` explicit arm was omitted because the compiler proves
`list_keys/0` type is `{:ok, integer(), map()}` (a literal error arm produced a
"clause will never match" warning); the guarded 3-tuple arm preserves the
runtime error path.

Fence (egress_dispatch_test.exs): GET /keys 200 shape preserved.

### Item 6 — CORS `origin: "*"` hardcoded (egress_router.ex)
Replaced the compile-time `plug(CORSPlug, origin: "*")` with a per-request
`plug(:egress_cors)` reading `Application.get_env(:smalt, :egress_cors_origins, ["*"])`.
Default unchanged; key documented in README.md (Authentication section, 8443
data-plane config docs).

Fences (egress_dispatch_test.exs): default `Origin: https://x.example` →
`access-control-allow-origin: *`; with `["https://allowed.example"]`
configured, listed origin answered, unlisted origin gets no header.

### Item 7 — KQL take cap fence (test-only)
audit_planes_test.exs: ingest 105 rows, `take 100000` → exactly 101 rows;
`take 50` → 50.

### Out of scope (unchanged, per WO)
`dspy/remediation.ex` — audited, release-ready.

## Verification

- `mix compile` — lane files clean (no new warnings).
- `mix test test/data_plane/audit_planes_test.exs` → **80 tests, 0 failures**.
- `mix test test/security test/dspy_test.exs` → **92 tests, 0 failures**.
- `mix test test/egress_dispatch_test.exs` → 95 tests, 5 failures —
  **pre-existing, not lane-19**: the identical 5 failures reproduce with my
  test block removed from the file (same seeds 1/2/3): lens7 fail-closed
  (KV/cosmos/ledger list surfaces, 3 tests), cosmos store_not_ready at
  dispatch, and "typed engine errors reach the wire at exact status". These
  live in other lanes' regions (fail-closed lens7 / blob XML arms landed by
  lane 06 / engine-kill lifecycle) and are order/lifecycle-dependent. All 8
  lane-19 fences pass (verified by line isolation and per-seed runs).
- CORS plug is runtime-evaluated per request (compile_env would have pinned
  the dev default into the module body and broken the allowlist fence).

## Standing

Items 1-7: ALIVE (observed execution — compile + suites above on this tree).
Pre-existing egress_dispatch failures: BLOCKED (owner: lane 06 / lens7 authors
/ coordinator integration wave).
