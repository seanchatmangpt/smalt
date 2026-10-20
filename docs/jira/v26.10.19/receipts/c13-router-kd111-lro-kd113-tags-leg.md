# c13-router-kd111-lro-kd113-tags-leg.md — ERRC RAISE lane (2026-10-19)

- **Lane**: C13-router (exclusive owner: `lib/smalt/arm_gateway/router.ex`)
- **Standing**: ALIVE (compile green; all witness legs witnessed on a live substrate with real curl output; internal tier carries 3 concurrent-lane failures NOT attributable to this lane)
- **Context**: slice (concurrent fan-out wave over one canonical checkout)

## Scope landed

1. **KD-111 LRO widening** — `lro_type?/1` widened from 2 to 6 types:
   Microsoft.ServiceBus/namespaces, Microsoft.EventHub/namespaces,
   Microsoft.KeyVault/vaults, Microsoft.DocumentDB/databaseAccounts (plus the
   original storage/compute pair). PUT create → 202 + Azure-AsyncOperation +
   Location + Retry-After; PUT update stays SYNC 200 for the widened types
   (new `lro_async_update_type?/1` keeps the original azurerm witness set
   200-async on update, unchanged); DELETE for these types was already sync
   200 (handle_child_delete) — unchanged. LRO Sweeper verified TYPE-BLIND
   (drives every InProgress `:smalt_operations` record by startedAtMs +
   delayMs — `lro_sweeper.ex` flip_pass/0) — no sweeper change needed.
   Marker: `# KD-COVERS: KD-111` at the widened `lro_type?/1`.
2. **KD-113 tags leg** — tags-at-scope routes: GET/PUT/PATCH on
   `/subscriptions/:sub/resourcegroups|resourceGroups/:rg/providers/Microsoft.Resources/tags`
   and `/tags/default` (12 route clauses, both RG segment casings). PUT =
   full replace, PATCH = merge, GET renders the `{"name":"default",
   "properties":{"tags":...}}` ARM envelope. Tags land on the RG record's
   "tags" member, so the RG GET normalize_tags/1 path and the RG delete
   cascade clear them with zero extra sweep code.
3. **Management locks** — `Smalt.Policy.lock_blocks?/2` has NOT landed
   (verified: no such export in `lib/smalt/policy.ex`). Typed-501 stubs per
   dispatch: GET list + PUT/DELETE `/providers/Microsoft.Authorization/locks`
   routes → 501 `LockSurfaceNotImplemented` (inline envelope, NOT
   send_arm_error/5 — its (status, code) set is pinned by arm_error_corpus).
   `# pending policy lane` call sites: the commented
   `Policy.lock_blocks?(sub_id, rg_name)` gate in `do_rg_delete/3` (delete →
   409 ScopeLocked once the policy lane lands) and in `handle_locks_stub/4`.

## Witness (live substrate, block 39040..39045, MIX_ENV=test, anonymous)

### KD-111 legs

```
-- LEG 1: SB namespace PUT create --
HTTP/1.1 202 Accepted
azure-asyncoperation: http://127.0.0.1:39040/subscriptions/s13/operations/e25673ba03739c4739515c2e
location: http://127.0.0.1:39040/subscriptions/s13/operations/e25673ba03739c4739515c2e
retry-after: 1
poll 1: Succeeded
-- LEG 1b: SB namespace PUT update -> sync 200 --
update 200
-- LEG 1c: KV vault + EH namespace + DocumentDB PUT create -> 202 --
kv 202
HTTP/1.1 202 Accepted   (EH, 1 azure-asyncoperation header)
docdb 202
-- LEG 1d: storage PUT (regression, still 202 create) --
storage 202
-- LEG 1e: storage PUT update (regression, still 200 async) --
storage-update 200
```

Post-poll GET proves the async create persisted the record (sku Premium
survived the sync-200 update leg):

```
{"id":".../Microsoft.ServiceBus/namespaces/sbns1",...,"sku":{"name":"Premium"},...,"type":"Microsoft.ServiceBus/namespaces"}
sb-get 200
```

Sync update carries no async headers:

```
HTTP/1.1 200 OK      (no azure-asyncoperation)
```

### KD-113 tags legs (lowercase resourcegroups variant; capital verified too)

```
tags PUT -> 200     {"name":"default","properties":{"tags":{"env":"c13","team":"router"}}}
tags PATCH -> 200   {"name":"default","properties":{"tags":{"env":"c13","extra":"1","team":"router"}}}
tags GET -> 200     {"name":"default","properties":{"tags":{"env":"c13","extra":"1","team":"router"}}}
rg tags: {'env': 'c13', 'extra': '1', 'team': 'router'}    (RG GET renders them)
RG DELETE -> 202
tags GET after delete -> 404 ResourceGroupNotFound          (cascade cleared)
tags-default PUT 200 -> GET {"name":"default","properties":{"tags":{"a":"1"}}}
```

### Locks stub legs

```
locks PUT -> 501     {"error":{"code":"LockSurfaceNotImplemented",...,"target":".../locks/l1"}}
locks DELETE -> 501  {"error":{"code":"LockSurfaceNotImplemented",...}}
```

## Verification ladder

- Compile: `MIX_BUILD_ROOT=_build-lane-c13 mix compile` — exit 0, green.
- `mix test test/internal/`: 29 tests, 3 failures — ALL concurrent-lane
  (certificates_kd104_witness_test.exs red + the census status-literal gate
  firing on other lanes' new files). None touch router.ex; disclosed, not
  attributable to this lane.
- Full offline `mix test` (lane build root): **50 tests, 2 failures** — the
  same two concurrent-lane failures as the internal tier (census
  status-literal gate on other lanes' new files; certificates_kd104_witness
  red). Zero failures attributable to router.ex; no router test exists in
  the mix tree (ARM surface is exercised via the live-witness probe above
  and the external TS suite).

## Cross-lane disclosures (compile-freeze SLA)

Two minimal unblock fixes applied to OTHER lanes' in-flight files while the
shared compile was frozen mid-wave; each disclosed here for the owning
lanes' receipts:

1. `lib/smalt/data_plane/kql.ex` — froze twice with syntax errors mid-edit;
   the owning lane repaired it themselves before I had to act (observed
   green on the next poll; no edit by me).
2. `lib/smalt/event_grid_webhook.ex` — `Smalt.EventGridWebhookPlug` called
   `get_req_header/2` with no Plug.Conn import. Minimal fix by me:
   `import Plug.Conn, only: [get_req_header: 2]` with a
   `Cross-lane unblock fix (compile-freeze SLA, c13-router lane)` comment.
   The owning lane has since edited the file further (their edits stand).

## KD register note

KD-111/KD-113 remain OPEN — the register flip is receipt-gated via
`scripts/kd_flip.py --apply` by the kd-registrar lane; this receipt is the
witness input, not the flip.
