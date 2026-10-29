# T30RA — Retry-After / SDK auto-retry parity audit (census only)

**Standing: PARTIAL_ALIVE**
Date: 2026-10-21
Mode: census only, no fixes.
Method: read `lib/smalt/egress_router.ex`, `lib/smalt/data_plane/{cosmos,blob_storage,blob_service,vault_data,queue_storage,appconfig_*}.ex`, `lib/smalt/egress/{Cosmos,Kv,AppConfig}Routes.ex`, `lib/smalt/arm_gateway/router.ex`, `lib/smalt/messaging/eh_throttle.ex`; greps for 429/412/409/500/503/Retry-After/x-ms-retry-after-ms/ServerBusy across `lib/`.

## Azure SDK auto-retry ground truth (azure-core default retry policy)

- Retried statuses: 408, 429, 500, 502, 503, 504.
- 429 honors `Retry-After` (seconds) or, for Cosmos REST, `x-ms-retry-after-ms`
  (milliseconds); without a header it falls back to exponential backoff.
- 5xx (500/502/503/504) retried on exponential backoff regardless of header.
- 412 PreconditionFailed: NOT retried (surfaces as the SDK exception /
  `CosmosClient` 412; CAS/optimistic-concurrency contract).
- 409 Conflict: NOT retried.
- Real Blob emits 503 ServerBusy (and 500) WITH `Retry-After`; real KV and
  Cosmos emit 429 with a retry hint under throttle.

## Census table

| Surface | Status smalt emits | Retry-After present? | SDK auto-retry behavior | Parity verdict |
|---|---|---|---|---|
| Cosmos (data plane, RU throttle) | 429 TooManyRequests | `x-ms-retry-after-ms: 1` (cosmos.ex:2311-2325) | Cosmos SDK retries after the ms hint | PARITY |
| ARM gateway (fixed-window throttle, router.ex:231) | 429 TooManyRequests | `retry-after: 1` | retried after hint | PARITY (not in the 5-surface scope but the only seconds-form header in the repo) |
| ARM gateway (StsGate DR, router.ex:265) | 503 StsUnavailable | `retry-after: 1` | retried (503 + hint) | PARITY |
| ARM LRO / RG delete | 202 + `retry-after: 1` | yes | poll interval honored | PARITY |
| Blob (data plane + egress) | no 429, no 503-ServerBusy face at all; 503 `RouteNotReady` (egress_router.ex:2432) | NO header | SDK still retries 503 on exponential backoff | DIVERGENCE (benign class): no throttle face emitted where real Blob can emit 503 ServerBusy + Retry-After; the RouteNotReady 503 retries but carries no hint |
| KV (vault data plane + KvRoutes) | no 429/503 throttle face; 409 Conflict (restore, vault_data.ex:66-83) | NO | 409 = never-retry, matches Azure | 409 PARITY; no throttle face (under-representation, benign) |
| App Config (AppConfigRoutes.ex) | 412 PreconditionFailed (x3 arms), 409 on missing If-Match delete + on unconditioned overwrite, 304 on If-None-Match GET | n/a | 412/409 never-retry, 304 terminal | PARITY |
| Cosmos CAS | 412 PreconditionFailed on etag mismatch (cosmos.ex:880, 1034, 1123, 1127); 409 Conflict (dup id / partition violation, cosmos.ex:492, 1001) | n/a | never-retry — matches Azure | PARITY |
| Blob CAS | 412 PreconditionFailed (If-Match mismatch, egress_router.ex:1587, 2242); 304 NotModified with etag echo | n/a | never-retry | PARITY (one ordering divergence below) |
| Blob delete precedence | WORM-locked + If-Match mismatch -> **409 ContainerLocked** where Azure answers **412 PreconditionFailed** (egress_router.ex delete arm; pinned in WIRE_PARITY.md row Blob Storage) | n/a | both no-retry — no SDK retry divergence | DIVERGENCE (contract-visible, not retry-class) |
| Queue Storage | 409 QueueAlreadyExists (queue_storage.ex:111); no throttle face | n/a | never-retry 409 | PARITY; no 503 ServerBusy face (benign) |
| Event Hubs | **NONE** — `Smalt.Messaging.EhThrottle` (eh_throttle.ex) defines the 429+`Retry-After` HTTP face and the AMQP `:resource_limit_exceeded` (server-busy) mapping, but has **zero callers in lib/ or test/** | n/a | nothing to retry on | GAP: EH quota engine is DEAD CODE; the w6au2 receipt itself stands PARTIAL_ALIVE |
| SB queues / DLQ | 409 class errors only; no throttle face | n/a | never-retry | PARITY for 409; no 429 ServerBusy face (real SB AMQP emits server-busy under throttle — under-representation) |
| Catch-all failure arms | blanket 500 (e.g. egress_router.ex:1172 `blob_error(conn, 500, inspect(other))`) | NO | SDKs retry 500s up to retry-budget then fail | DIVERGENCE (benign): untyped 500s are retried N times where real Azure would usually answer a typed 4xx (never-retry) — wasted retries, then failure |

## Findings (ranked)

1. **F1 (retry-divergence, real): Event Hubs throttle is unwired.**
   `EhThrottle.admit/3` / `EhThrottle.retry_after/1` / `amqp_refusal/1` are
   never invoked outside their own module. The AMQP link path never maps a
   refusal to the server-busy class and the HTTP/ARM path never renders
   429 + `Retry-After`. An SDK pointed at smalt EH sees an unthrottleable
   endpoint: over-quota publishes silently succeed where real EH would
   429/server-busy. Retry-forever: no. Retry-never: no — but the face is
   absent entirely. Receipt w6au2-eh-throttle.md already discloses
   PARTIAL_ALIVE (engine-only).
2. **F2 (hint-parity): no seconds-form `Retry-After` on any data-plane 503.**
   `route_not_ready/1` (egress_router.ex:2432-2437) sends 503 RouteNotReady
   with x-ms-request-id/x-ms-version only. azure-core still retries 503
   (exponential), so this is not a never-retry trap — but real Blob/Queue
   503s carry `Retry-After`. Divergence is hint-absence, not retry class.
3. **F3 (no retry-forever face anywhere).** No smalt face emits an
   unbounded/huge Retry-After, and no face maps a non-retryable condition to
   a retryable status. The one candidate class (blanket 500 arms) only burns
   the SDK retry budget, never loops forever.
4. **F4 (ordering divergence, no retry impact): blob delete checks WORM
   (409) before If-Match (412)** — real Azure evaluates preconditions first
   and answers 412. Both statuses are SDK-never-retry, so no retry behavior
   change; contract-visible only.
5. **F5 (under-representation, benign):** Blob/Queue/KV/SB have no throttle
   faces at all (no 503 ServerBusy, no 429). Real Azure surfaces can emit
   these under load; an SDK will never see them from smalt. Census-level gap,
   not a wire-visible wrong face.

## Retry-forever / never-retry flags (the explicit ask)

- **Retry-forever: NONE found.** No emitted face supplies a Retry-After that
  would keep an SDK in an unbounded retry loop, and no wrong-class status
  would.
- **Never-retry where Azure retries: NONE as a status class.** All 429/503
  faces smalt emits carry retryable statuses. The nearest miss is F2 (503
  RouteNotReady without a hint — still retried via exponential backoff) and
  F5 (faces absent, so SDK has nothing to retry on — behaves as "succeeds",
  not "fails forever").

## Standing

PARTIAL_ALIVE. The surfaces that DO emit throttle faces (Cosmos 429 with
x-ms-retry-after-ms, ARM 429/503 with Retry-After) are parity-correct with a
1s/1ms hint. The gaps are absence-class: EH throttle unwired (F1), no
data-plane ServerBusy faces (F5), no hint on RouteNotReady (F2). No fixes
applied per census scope.
