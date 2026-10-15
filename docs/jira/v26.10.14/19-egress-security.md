# V261014-19 — Egress Security & Envelope Correctness Sweep

- **Release:** v26.10.14 · **Status:** ready for implementation
- **Area:** egress router, Sentinel (Log Analytics), Resource Graph, SKR vault path
- **Verification suites:** `test/security/*`, `test/data_plane/audit_planes_test.exs`, `test/egress_dispatch_test.exs`, `test/dspy_test.exs`
- **Coordinates:** `lib/smalt/egress_router.ex` is shared with lane 06 — this lane owns the SKR/KV arms, CORS plug, and the `get "/keys"` catch-all; lane 06 owns the blob route arms + `blob_error` funnel.

## Summary

Seven findings, all re-verified against source. Six are code fixes with fence tests; one (Item 7) is a fence test only. `dspy/remediation.ex` was audited and is release-ready — explicitly no work.

## Item 1 — SKR 200 leaks blob-plane headers on KV route (F5 law violation)

**Severity:** High. **Files:** `lib/smalt/egress_router.ex`.

The `post "/keys/:name/release"` route (~:456-462) renders success through the blob-scoped renderer:

```elixir
{:ok, status, body} -> blob_error(conn, status, body)
```

`blob_error/3` stamps `x-ms-request-id` + `x-ms-version` on every response, so KV release **200s carry blob headers**, violating the router's own F5 law (~:1836-1839: "blob_error blob-plane-scoped … KV envelope pins must not see blob headers"). Every other KV route uses `send_json`/`kv_respond` (:367, :447, :1884-1885).

**Fix.** `{:ok, status, body} -> send_json(conn, status, body)`; align the `{:error, ...}` arm to `send_json` as well after confirming no pin depends on blob headers on KV error envelopes.

**Pre-check (required).** `grep -rn "x-ms-request-id" test/security test/data_plane` (2026-10-15): blob-plane pins only; **no test currently pins the header-emitting 200 on the release route.** If re-grep at implementation time finds a pin, update it with an explicit disclosure note in the commit message — never silently.

**Fence.** POST a successful release; assert `x-ms-request-id` and `x-ms-version` are **absent** from the 200 headers; body unchanged.

## Item 2 — Sentinel DCR↔workspace coupling: `:dcr_created` marker never produced by lib

**Severity:** Medium (dead safety fence). **Files:** `sentinel.ex`, `audit_planes_test.exs`.

Rows are keyed `"#{dcr}/#{stream}/#{seq}"` (`row_key/3`, :317) but `query/2` scans `"#{workspace_id}/"` (~:208) — DCR↔workspace equivalence is by-convention only, holding when `workspace_id == dcr`. The `:sentinel_dcr_strict` fence (~:46-53) pivots on `dcr_exists?/1` checking `{:dcr_created, dcr}` in `:smalt_sentinel_streams` — a key **only tests write** (`audit_planes_test.exs:770`). Strict mode would 404 every DCR that tests did not hand-seed: the fence pivots on state nothing can create.

**Fix (recommended, option a).** In `do_ingest/3` (~:117), after the stream `Store.put`, add:

```elixir
Store.put(:smalt_sentinel_streams, {:dcr_created, dcr}, true)
```

(small, idempotent, makes strict mode meaningful). Option (b) — document `workspace == dcr` as a pinned divergence — fallback only if (a) breaks an existing pin; check the DCR/stream assertions before merging.

**Fence.** (1) Ingest to a fresh DCR, flip `:sentinel_dcr_strict` true, re-ingest → 204; query by `dcr` as workspace returns the rows. (2) Ingest to a never-created DCR under strict mode → 404 `DCRNotFound`.

## Item 3 — ResourceGraph unvalidated `subscriptions` shape → mis-blamed 400

**Severity:** Medium. **Files:** `resource_graph.ex`, `egress_router.ex`.

`matching_resources/1` (~:173-180) has only `nil` and `is_list` clauses. A string/map body → `FunctionClauseError`, which escapes the `{:bad_query, _}` catch (:31-36); `safe_dispatch/2` (~:1551-1558) rescues it as **400 InvalidBody** — wrong envelope for a shape error, never a typed `InvalidParameter`.

**Fix.** Validate `subscriptions` before dispatch: accept `nil` and `is_list` with all-binary elements; anything else → `{:error, 400, %{"error" => %{"code" => "InvalidParameter", "message" => ...}}}` — typed, never 500, never a silent all-resources result.

**Fence.** POST query bodies with `"subscriptions": "sub-1"` (string) and `{"a": 1}` (map) → 400 `InvalidParameter`; not 500; not unfiltered.

## Item 4 — `:smalt_resource_graph_tokens` unbounded (no TTL, no cap)

**Severity:** Low. **Files:** `resource_graph.ex` (~:209-227).

**Fix (preferred).** Cap + TTL: on mint, sweep expired entries (`created_at` older than `@token_ttl` = 15 min); when the table exceeds `@token_cap` (e.g. 1000), evict oldest-first; expired/unknown tokens take the existing unknown-token error path. **Fallback (acceptable):** document the caveat inline at `new_token/3` + moduledoc ("emulator-only table, unbounded within a run") — coordinator accepts documentation given emulator scope.

**Fence.** If implemented: mint past cap/TTL, assert old tokens refused, new ones work. If documented-only: note the decision in the completion log.

## Item 5 — `get "/keys"` catch-all crashes on non-3-tuple

**Severity:** Low (latent 500 outside `safe_dispatch`). **Files:** `egress_router.ex` (~:477).

The catch-all `other -> send_json(conn, elem(other, 1), elem(other, 2))` raises `ArgumentError` on a non-3-tuple, outside `safe_dispatch`.

**Fix.** Explicit arms `{:ok, s, b}` / `{:error, s, b}` plus a final fallback arm answering a typed 500 envelope (log-and-500), so no return shape becomes an unhandled raise.

**Fence.** Normal `list_keys` 200 shape preserved; the handler arms are total (unit-level assertion acceptable if a bad tuple cannot be injected via the public surface).

## Item 6 — CORS `origin: "*"` hardcoded on 8443

**Severity:** Low (config hygiene). **Files:** `egress_router.ex` (~:37).

**Fix.** `origin: Application.get_env(:smalt, :egress_cors_origins, ["*"])` with `*` as the documented dev default; document the key in the 8443 config docs.

**Fence.** Default unchanged (`Origin: https://x` → `access-control-allow-origin: *`); with a list configured, a non-listed origin gets no allow-origin header and a listed one does.

## Item 7 — KQL `take` cap fence (test-only)

Legacy `take N` is capped at `@max_take` = 101 (`parse_take/1`, ~:293); no test pins it. One fence test: ingest > 101 rows, `take 100000` → exactly 101 rows; `take 50` → 50.

## Out of scope

`dspy/remediation.ex` — audited, release-ready, no changes.

## Acceptance criteria

1. Every code item (1-6) lands with its fence test; item 7 is its own fence.
2. SKR release 200s carry no `x-ms-request-id` / `x-ms-version` (asserted absent).
3. Hostile `subscriptions` shapes → typed 400 `InvalidParameter` — never 500, never silent all-resources.
4. The pre-check grep outcome recorded; any affected pin updated with disclosure.
5. Suites green: `test/security/*`, `test/data_plane/audit_planes_test.exs`, `test/egress_dispatch_test.exs`, `test/dspy_test.exs`.
