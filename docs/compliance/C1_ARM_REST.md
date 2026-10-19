# C1 — Azure ARM REST Compliance

# C1_ARM_REST

## Scope

Subject: `Smalt.ArmGateway.Router` (`lib/smalt/arm_gateway/router.ex`) +
`Smalt.ArmGateway.LRO` (`lib/smalt/arm_gateway/lro.ex`), smalt v26.10.14,
at the live HTTP wire, verified against the ARM REST API contract
(azure/azure-rest-api-specs guidance: error response, async operations,
api-version semantics, list envelopes, status-code semantics).

Method: live wire probes — `Smalt.ArmGateway.Router` booted under Bandit on an
ephemeral port per test, real HTTP via inets `:httpc` (no doubles). Fence
tests: `test/compliance/c1_arm.exs` (26 tests, 0 failures, 2026-10-18 re-measured via the
compliance loader `mix test test/compliance_test.exs` -> `157 tests, 0 failures (16 excluded)`).
Suite setup is the canonical resilient shared-Store helper (`test/support/store_resilient.ex`
`SmaltTest.Store.resilient_clear/1` — bounded typed retry around
`Lifecycle.ensure_store_up()` + `Store.clear/0`, rescuing ONLY the dead-table
`ArgumentError`, i21/i22 hardening; the c1 variant runs its subscription
`post_seed` INSIDE the retry window so a seed racing the same dead-table window
is retried too).

## Receipt

- Subject: smalt v26.10.14 `Smalt.ArmGateway.Router` + `Smalt.ArmGateway.LRO`
- Probe transport: Bandit ephemeral listener + `:httpc` (inets), real sockets
- Commands: `mix test test/compliance/c1_arm.exs` → `26 tests, 0 failures` (lens-9 re-measured)
- Replay: `cd ~/smalt && mix test test/compliance/c1_arm.exs`
- Standing: PARTIAL_ALIVE (22 CONFORMANT (21 fenced; 4 + 1b fixed 2026-10-15),
  1 PARTIAL (5b), 0 GAP)
- Falsifier: any fence test failing, or any CONFORMANT row's live probe
  diverging from the md row without an md update in the same change.

## Compliance rows

| # | Row | Standing | Spec clause | smalt evidence |
|---|-----|----------|-------------|----------------|
| 1a | Error envelope `error.code` + `error.message` on all failures | CONFORMANT (fenced) | ARM error response: body `{ "error": { "code", "message" } }` | `router.ex:531-560` `send_arm_error/4`; live 404: `{"error":{"code":"ResourceGroupNotFound","message":"Resource group 'rg1' could not be found."}}` |
| 1b | `error.target` on validation refusals | CONFORMANT (fenced) | error.target optional; required semantically when a specific path caused the failure | every 404 class now carries `target` naming the offending path (`send_arm_error/5` with target: ResourceGroupNotFound→RG id, ResourceNotFound→resource id, SubscriptionNotFound→subscription id, RouteNotFound/ActionNotFound/OperationNotFound→request path); api-version 400s pinned target-ABSENT (query-param failure, corpus refutes); fence: `c1_arm.exs` row-1b test |
| 1c | `error.innererror` | CONFORMANT (fenced) | ARM error model allows nested `innererror` | every error envelope carries `"innererror":{}` present-but-empty (real-AAD shape): `send_arm_error/4` + `send_graphlaw_refusal/2` + the inline 429 envelope; live 404: `{"error":{"code":"ResourceGroupNotFound",...,"innererror":{}}}`; fence asserts `innererror == %{}` on 404 and 400 |
| 2a | Success envelope id/name/type/location/properties.provisioningState | CONFORMANT (fenced) | ARM resource envelope | `router.ex:660-671`, `router.ex:1075-1084`; live: 202 PUT storageAccount then GET 200 → full envelope, provisioningState Succeeded |
| 2b | `systemData` | CONFORMANT (fenced) | ARM envelope carries `systemData` (createdBy/type, createdAt) | synthetic fixed `@system_data` (`createdBy "smalt-dev-substrate"`, `createdByType "Application"`, fixed createdAt) on RG/resource/child records (`handle_rg_put/3`, `handle_resource_put/5`, `handle_child_put/5`); honest dev-mode — no fabricated per-caller values; fence asserts the fixed triple on PUT 201 + GET 200 |
| 3a | PUT create 201 / update 200 (non-LRO) | CONFORMANT (fenced) | ARM sync PUT semantics | `router.ex:805-874`, `router.ex:618-677`; live: disks 201 then 200 |
| 3b | PUT 201/200 for LRO types | CONFORMANT (fenced) | ARM LRO PUT: create → 202 + async headers, update → 200 + async headers | `router.ex` `handle_resource_put` cond: `lro_type? and not existed?` → 202; `lro_type?` (update) → 200; both via `async_put_response/3` (`router.ex:860-872` cond, `router.ex:2139-2146` headers); live: create 202 then update 200, both carry Azure-AsyncOperation + Retry-After |
| 3c | 202 must carry Azure-AsyncOperation (+ Retry-After) | CONFORMANT (fenced) | ARM async operations | (`router.ex:2139-2146`); live: `azure-asyncoperation`, `location`, `retry-after: 1` all present on 202 |
| 4 | DELETE semantics | CONFORMANT (fenced) | ARM: RG delete is LRO → 202 + Location; sync delete → 200 (body) or 204; final GET 404 | `handle_rg_delete/2` (`router.ex:708`): 202 + `Location` polling URL (request authority) + `Retry-After: 1`, operation record backs the polling URL so the delete poll terminates; sync resource delete → 200 empty; final GET 404 CONFORMANT; fence asserts 202 + Location ops path + Retry-After + final 404 (`c1_arm.exs` RG lifecycle test) |
| 5 | LRO terminal GET shape `{status, ...}` | CONFORMANT (fenced) | ARM operation-status resource | poll route `router.ex:2607`; completion flip is one-writer (`lro.ex:378-423` `evaluate/2`/`fail_closed/2`, sole writer `Smalt.ArmGateway.LRO.Sweeper` `lro_sweeper.ex:73-88`); live: poll → 200 `{"status":"Succeeded", ...}` |
| 5b | `error` member on failed operation | PARTIAL | operation status carries optional `error` | the one-writer redesign closed the no-Failed path: the Sweeper is the SINGLE terminal writer (the only flip-path invoker of the public `evaluate/2`/`fail_closed/2`, `lro.ex:378-423`); `get_op/1` is a PURE READER that routes its persistence through the writer (`lro.ex:70-107`); malformed/missing-scheduling records fail closed to a persisted Failed terminal (`OperationRecordIncomplete`) via the same writer (`lro.ex:323` `fail_closed_via_writer/2`) |
| 6a | Missing api-version → 400 `MissingApiVersionParameter` | CONFORMANT (fenced) | ARM api-version semantics | `router.ex:1923-1936` (`check_api_version/2` -> `check_version/3` `router.ex:1947-1949`); live: GET without api-version → 400 `{"error":{"code":"MissingApiVersionParameter",...}}` |
| 6b | Invalid api-version → 400 `InvalidApiVersionParameter` | CONFORMANT (fenced) | enforced on every verb | PUT validates against `Registry.latest_version` (`check_version/3`); GET now passes the REQUESTED type (resource/child get/list/delete) so `check_version/3` validates instead of short-circuiting `:ok` on `nil`; live: GET storageAccounts with `api-version=1999-01-01` → 400 `InvalidApiVersionParameter`; **row 6b fully closed 2026-10-15 (coordinator-authorized same-landing)**: the resource-group CRUD routes (`handle_rg_list/put/get/delete`) now gate on `check_api_version/2` against the admitted `Microsoft.Resources/resourceGroups` type (latest 2021-04-01) — missing → 400 `MissingApiVersionParameter`, stale → 400 `InvalidApiVersionParameter` naming the latest, on all four verbs; every consumer call site updated in the same landing (see tmp/errc/arm-gateway/cycle-7.md for the per-file disclosure); fence: `c1_arm.exs` "resource-group verbs enforce api-version on all four verbs" |
| 6c | Bad-value error message names the latest supported api-version | CONFORMANT (fenced) | good practice per ARM guidance | `router.ex:1985-1991` message embeds the latest supported version |
| 7a | `resourcegroups` vs `resourceGroups` segment | CONFORMANT (fenced) | ARM path segments after /subscriptions/{sub}/resourcegroups are case-insensitive | both spellings routed (`router.ex:2630-2651`); live: PUT `resourceGroups/rg-...` then GET `resourcegroups/rg-...` → 200 |
| 7b | Provider namespace case-insensitivity | CONFORMANT (fenced) | provider namespace case-insensitive | `find_admitted/1` downcases (`router.ex:2124-2128`); store keys downcased; live: PUT `Microsoft.Storage` → GET `microsoft.storage` → 200 |
| 8 | LIST envelope `{"value": [...]}` | CONFORMANT (fenced) | ARM list envelope | `send_list/2` `router.ex:433-452`, RG list `router.ex:609-616`, envelope literal `router.ex:411`; live: storageAccounts LIST → `{"value":[...]}` incl. created record; RG LIST entry pinned to exact envelope (id/type/location/`properties.provisioningState=="Succeeded"`) (c1 fence, 2026-10-15) |
| 9 | `nextLink` pagination | CONFORMANT (fenced) | ARM lists paginate via `nextLink` when large | `send_list/2` pages at 100 (`@page_size`), `maxitempages` (default 1) caps pages per response; truncated lists carry an absolute nextLink (request authority) with `$skip` + `maxitempages`; applied to RG LIST, child lists and per-RG provider-type LIST; live: 105 disks → page of 100 + nextLink `http://127.0.0.1:{port}/...$skip=100&maxitempages=1`, follow → 5 + no nextLink |
| 10 | Operation-Location / Azure-AsyncOperation URL shape | CONFORMANT (fenced) | polling URL must be resolvable from the client's seat | headers present (`async_put_response/3`), path `/subscriptions/{sub}/operations/{id}` served; host = `request_authority/1` (same derivation as the OIDC envelopes) — live: header carries `http://127.0.0.1:{listener-port}`, no `management.smalt.local` anywhere |
| 11 | `x-ms-request-id` echo | CONFORMANT (fenced) | ARM responses echo a request id + `x-ms-request-id` response header | `arm_request_id/2` plug (`router.ex:53,101`; wired `router.ex:53-54`) mints an RFC 4122 v4 UUID (or echoes the client's `x-ms-request-id`) and attaches it via `register_before_send` so EVERY response — including 429s and error envelopes — carries it; fence asserts a 36-char UUID on 404 and verbatim echo of a client-supplied id |
| 12 | 429 + Retry-After on throttling | CONFORMANT (fenced) | ARM throttling responses carry 429 + Retry-After | `arm_throttle/2` plug (`router.ex:54,132`): ARM-wide fixed-window (1s) counter in `:smalt_arm_rate` ETS, gated on `Application.get_env(:smalt, :arm_rate_limit, :infinity)`; default :infinity → byte-identical (fence: 60 rapid PUTs, zero 429s); when configured, exceeding the limit → 429 + `retry-after: 1` + `TooManyRequests` envelope with innererror (inline envelope — not send_arm_error, preserving the arm_error_corpus pinned set). Mirrors the cosmos `:cosmos_ru_limit` gate (`cosmos.ex` throttle/2) |
| 13 | Content-Type `application/json; charset=utf-8` | CONFORMANT (fenced) | ARM responses are JSON | `put_resp_content_type("application/json")` (`router.ex:186`); live header exactly `application/json; charset=utf-8` on 200/201/202/400/404 |

## Known-gap summary (load/protocol parity debts)

1. **Polling-host GAP (row 10)** — CLOSED 2026-10-14: `async_put_response/3`
   uses `request_authority/1` for Azure-AsyncOperation/Location.
2. **GET bypasses api-version validation (row 6b)** — CLOSED 2026-10-14: the
   GET handlers pass the requested resource type, so `check_version/3`
   validates like PUT.
3. **LRO types never return 201/200 on PUT (row 3b)** — CLOSED 2026-10-14:
   create → 202 + async headers, update → 200 + async headers.
4. **No delete LRO (row 4)** — CLOSED 2026-10-15: `handle_rg_delete/2` returns
   202 + Location + Retry-After with an operation record backing the polling
   URL (delete poll terminates); fence updated in the same change.
5. **x-ms-request-id, 429, nextLink, innererror, systemData
   (rows 1c, 2b, 9, 11, 12)** — CLOSED 2026-10-14: `arm_request_id/2` +
   `arm_throttle/2` wire plugs (request-id echo on every response; ARM-wide
   429 + Retry-After gated on `:smalt, :arm_rate_limit`, default :infinity),
   `send_list/2` nextLink pagination (100/page, `maxitempages`), innererror in
   every error envelope, synthetic fixed systemData on resource records.

## Typed gap register (`GAP(name)` tokens, wire-parity §4 convention)

Machine-greppable tokens per the `docs/XAAS_PRIOR_ART.md` §4 item-5
adopt-now convention; each token names a load/protocol parity debt with an
owning surface and a close condition. Adopted by the arm-gateway lane
2026-10-15 (lens-7).

| Token | Row | Standing | Debt | Close condition |
|---|---|---|---|---|
| lro-no-failed-path | 5b | CLOSED 2026-10-15 (lens-9 cycle-1), token retired | — | closure: `evaluate/1`'s catch-all flips an incomplete InProgress record to a persisted Failed terminal with `error.code="OperationRecordIncomplete"` (`lro.ex:378-423`; sole writer `lro_sweeper.ex:73-88`); fences c1 row-5b + `lro_test (13)` green, M48/M49 killed |
| lro-lazy-terminality | 5 | CLOSED 2026-10-15 (V261014-05), token retired | — | closure: `Smalt.ArmGateway.LRO.Sweeper` (`lib/smalt/arm_gateway/lro_sweeper.ex`) periodic flip pass driving the same public `evaluate/2`/`fail_closed/2` as the lazy path; fences `lro_test (10)/(10b)/(12)/(13)` green |
| lro-retention-unbounded | — | CLOSED 2026-10-15 (V261014-05), token retired | — | closure: opt-in `:lro_retention_ms` (default `:infinity`), terminal-only oldest-first eviction; fences `lro_test (10)/(10c)/(10d)` green |

**Sweeper work order shape** (IMPLEMENTED v26.10.14, V261014-05 — was
engine-Raise candidate, FEATURE BAN, lens-8 cycle 2):

- **Trigger**: periodic `Process.send_after` loop in a dedicated
  `Smalt.ArmGateway.LRO.Sweeper` GenServer, interval
  `Application.get_env(:smalt, :lro_sweep_interval_ms, 30_000)`; started under
  the gateway supervision tree, never under a request process (the lens-2
  regression class).
- **Scan**: `Store.list(:smalt_operations)` → for each InProgress record with
  `startedAtMs + delayMs <= now`, persist the identical terminal record the
  lazy path computes (same `evaluate/1` shape: delete scheduling fields, set
  status Succeeded, set `endTime`) — one shared pure function so the sweeper
  and the lazy path cannot diverge. Records missing scheduling fields
  (livelock face): **RESOLVED lens-9** — the shared pure function now types
  them terminal-Failed (`OperationRecordIncomplete`, error member set); the
  sweeper must reuse the same function so lazy and swept records converge to
  the identical persisted terminal. Records with a MISSING or non-binary
  "status" member: **RESOLVED lens-10** — `get_op/1` fails them closed
  (bypassing the scheduling clause) to the same persisted Failed terminal;
  fence `lro_test (20)` pins both the valid-scheduling and no-scheduling
  variants; the sweeper must reuse the same fail-closed function.
- **Eviction interaction** (with the retention closure — CLOSED
  2026-10-15, lane-05 receipt): eviction eligibility = terminal AND older than
  the retention window, evaluated AFTER the sweep flips, oldest-terminal-first
  per the lens-7 parked design; the sweep itself never deletes.
- **Fences**: (a) `lro_test (10)` retention run converts to no-poll + sweep +
  raw read; (b) `lro_test (13)` per above; (c) new fence: sweep on an empty
  store and a store of all-terminal records is a no-op (0 writes witnessed via
  a record-count/`endTime`-stability pin); (d) concurrency fence: sweep
  racing a wire poll on the same record converges to ONE persisted terminal
  record (idempotent put, byte-identical body).
- **Falsifier**: a record past `startedAtMs + delayMs + sweep_interval` that
  was never polled still reads InProgress at raw `Store.get` after the sweep
  pass → work order not closed.

## LRO one-writer mechanism (v26.10.18 redesign)

Since the v26.10.18 one-writer redesign (`rewrite-drafts/lib-redesign-wasm-lro.md`
Part 2), LRO terminal convergence is OWNED, not emergent:
`Smalt.ArmGateway.LRO.Sweeper` is the SINGLE terminal writer — the only
process that invokes the public `evaluate/2` / `fail_closed/2`
(`lro.ex:378-423`) on the flip path. The read path (`get_op/1`) is a PURE
READER that never calls `Store.put` itself; a due InProgress record computes
its terminal VIEW in memory and routes persistence through a synchronous
writer call (`{:flip_due, key}` / `{:fail_closed, key, record}`,
`lro_sweeper.ex:73-88`), and the sweeper publishes each terminal through
`Smalt.ArmGateway.LRO.Notifier` so `await/3` waiters wake on the explicit
signal. If the sweeper is down, the computed VIEW is returned (fail-safe,
disclosed: store convergence then waits for the next sweep pass, bounded by
the sweep interval). The earlier "evaluate/1 lazy-persist" description is
superseded by this note.

## Fenced surface

`test/compliance/c1_arm.exs` pins rows 1a, 1b, 1c, 2a, 2b, 3a, 3b, 3c, 4, 5,
6a, 6b (both verbs), 7a, 7b, 8, 9, 11, 12, 13. 26 tests,
`mix test test/compliance/c1_arm.exs` →
`26 tests, 0 failures` (run 2026-10-15, lens-9 re-measured).

## See Also

- `test/compliance/c1_arm.exs` — fence tests (live wire tier)
- `test/lro_test.exs`, `test/smalt_arm_gateway_test.exs` — functional tests
- ARM REST guidance: async operations, error responses, api-version handling
  (azure/azure-rest-api-specs documentation)
