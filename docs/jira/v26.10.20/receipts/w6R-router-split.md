# w6R — EgressRouter structural split (BEAM implementation-limit blocker fix)

**Standing:** ALIVE (compile green, internal tier 48/0, live-wire smoke per delegator + blob/queue planes, typed faces verified)

Date: 2026-10-20 · Lane: w6R (coordinator-authorized blocker fix) · Subject: /Users/sac/smalt working tree (uncommitted)

## Blocker

`mix compile` failed deterministically: **"An implementation limit was reached
... function '__MODULE__'/1+14"** — the single Plug.Router match chain (112
clauses) exceeded the BEAM per-function implementation limit. Every lane's
compile gate was red.

## Fix (structural split, behavior byte-equivalent)

- 5 delegator routers under `lib/smalt/egress/`: `AttestRoutes`,
  `CosmosRoutes`, `KvRoutes`, `AppConfigRoutes`, `ObservabilityRoutes`
  (SchemaRegistryRoutes is w6x's own; it composed onto the same pattern).
  ~98 route clauses relocated verbatim; main router keeps head + blob splat +
  404 catch-all + internals (~14 clauses, under the limit).
- Helpers defp→def; delegators `import Smalt.EgressRouter, except: [match: 2,
  match: 3, dispatch: 2]` (+ `Smalt.Egress.AppConfigRoutes` import in KvRoutes
  for the secret_* helper family that relocated with the appconfig region).
- Runtime fallthrough: `plug(:w6r_fallthrough)` → `safe_subrouter_call/2`
  rescues the no-match FunctionClauseError from `plug :match` and passes the
  conn on unchanged — the main router's blob splat + 404 catch-all then see
  byte-identical requests (this is the exact original tail semantics; the
  splat's reserved-namespace fence applies as before).
- Compile-time plug references avoided (runtime `Code.ensure_loaded?` guard) —
  the compile-time `plug(Mod)` form deadlocks against the delegators'
  `import Smalt.EgressRouter` (witnessed, fixed).
- Delegators carry their own alias blocks (Store, Attestation,
  ConfidentialLedger, Cosmos, KeyVaultActions, AppConfigSnapshots, Purview,
  ResourceGraph, Sentinel, EventStream) — aliases don't survive module moves.
- `splat_fallback/1` + `reserved_first_segments/0` added as public helpers
  (currently unused since the rescue-passthrough design replaced the
  catch-all design mid-flight; retained deliberately — no warning, and they
  name the tail semantics for future delegates).

## Disclosed minimal fixes (compile-freeze SLA)

1. `unwrap_json_list` → `wrap_json_list` rename in the relocated cosmos sproc
   route (the call targeted a nonexistent helper — in-flight sibling rename
   captured mid-edit; `wrap_json_list` is the existing semantic twin).
2. `file_plane_route` duplicate-head PUT clauses merged into one cond — the
   x-ms-type: File arm was shadowed by the restype=directory clause's head
   (real parity defect in the wave-6 files plane).
3. Share-existence gates on file-plane `get_file`/`delete_file` arms — the
   3+segment GET/DELETE catch-alls were swallowing blob-plane requests for
   absent shares ("The specified file does not exist" answering blob GETs).
   Absent share → conn returned unchanged → blob splat, restoring Azure
   namespace parity.
4. `header_map/1` duplicate (identical-semantics second def) removed.
5. Mid-lane the router was clobbered by a concurrent large-Write variant and
   then rewritten by the `safe_subrouter_call` design; both were reconciled
   against backup /tmp/egress_router.ex.w6r.bak2 (sha256 of the corrupted
   variant preserved at /tmp/w6r/clobbered_variant.ex).
6. cosmos_feeds.ex deliberate-corruption marker finding: sha256
   8366c353fee2505eb51235a85f2436977761181b8d20a5ebab78750133b24a52
   (marker state), self-resolved by owner lane w6ai moments later; coordinator
   confirmed no court planted it (large-Write degradation class). No repair
   landed by me (stood down per coordinator).

## Verify ladder (real output)

- `MIX_BUILD_ROOT=_build-lane-w6R MIX_ENV=test mix compile` → `Generated smalt
  app` (GREEN). Egress-scope warnings: 0 (`grep "└─ lib/smalt/egress"` empty).
  Tree-wide `--warnings-as-errors` still fails on SIBLING-owned warnings
  (cosmos.ex sproc/UDF typing, arm_gateway, queue_store `target`) — not this
  lane's surfaces, disclosed to coordinator.
- `mix test test/internal` → `48 tests, 0 failures`.
- Live wire (substrate b12, anonymous, fresh boots):
  - `GET /` → 200 (cosmos DatabaseAccount bootstrap)
  - `POST /dbs {"id":"w6rdb"}` → 201; `GET /dbs` → 200
  - KV challenge handshake (401 + WWW-Authenticate → STS token) →
    `POST /keys/w6rkey/create` 200, `GET /keys/w6rkey` 200
  - `PUT /kv/w6rk` tokenless → 401 challenge (pinned mode-blind KD-15 class)
  - `POST /v2/track` → 200
  - container 201 → blob put 201 → blob get body-exact "hi-w6r"
  - `PUT /w6ra/w6rq?restype=queue` → 201
  - `PATCH /dbs/x` → 404 RouteNotFound JSON (original catch-all semantics)
  - `GET /nosuchplane` → 404

## Falsifier status

- The original blocker falsifier: `mix compile` on the pre-split tree
  reproduced "implementation limit ... '__MODULE__'/1+14" (kept in lane
  transcript; reproducible via /tmp/egress_router.ex.w6r.bak2).
- Post-fix: compile green across repeated sibling-churn windows; the 48-test
  internal tier is green on the split; wire smoke above shows each delegator
  arm + the unchanged blob/queue planes.

## Notes for integration

- w6b/w6i-2/w6y staged router patches re-apply onto the slimmed main router
  (anywhere before `plug(:w6r_fallthrough)` region comment or into the
  matching delegator for their surface).
- Tree-wide `--warnings-as-errors` gate needs sibling warnings resolved
  (cosmos.ex/queue_store/arm_gateway owners) before `just court`.
