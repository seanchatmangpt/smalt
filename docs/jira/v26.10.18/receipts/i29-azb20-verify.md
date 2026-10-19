# Receipt: i29-azb20-verify — AZB-20 gap-fix lane verification

- **Standing**: PARTIAL_ALIVE — cosmos bulk partition-key cell CLOSED (full 20-probe witness, both bulk cells PASS); control-plane cells (header-audit x-ms-request-id, ARM control 500s, ARG-on-control 404, KV control 503) all REPRODUCED still-OPEN at the gap-fix tree.
- **Context**: solo (test/data_plane/ test/arm/ test/wire/ tiers + `just azsim-sdk` matrix + standalone cosmos probe rerun)
- **Date**: 2026-10-19
- **Subject**: shared dirty tree at HEAD `086c6aa` + in-flight gap-fix diffs in
  `lib/smalt/arm_gateway/router.ex`, `lib/smalt/data_plane/{blob_storage,cosmos,key_vault_actions}.ex`,
  `lib/smalt/egress_router.ex` (354 insertions). The gap-fix receipt (`azb-20-gap*` /
  `i29-azb20-fix`) has NOT landed in `docs/jira/v26.10.18/receipts/` — this verification ran
  against the on-disk diffs without it.
- **Commit**: not minted (no-git constraint)

## Gate 1 — test tiers (green)

```
MIX_BUILD_ROOT=_build-ft-az20 mix test test/data_plane/ test/arm/ test/wire/
→ 500 tests, 0 failures (2 excluded), 19.3s
```

No LOAD-class failures. Note: `lib/smalt/data_plane/key_vault_actions.ex` carries a
compile-freeze-SLA disclosure comment ("UNBLOCK-FIX (lane shim-court-repair, 2026-10-18)":
restored `purge_deleted_key`'s closing `end` consumed by a sibling lane's in-flight
`update_key_properties`) — the shared compile is green on this tree.

## Gate 2 — `just azsim-sdk` per-plane matrix

Environment: private block 39443-39475 lsof-verified free before boot; canonical 9443/8443
held by an ssh tunnel (pid 61023, another lane's) — never touched, no evictions.
`MIX_BUILD_ROOT=_build-ft-az20`. Attempt 1 was killed at my 10-min background cap
(signal 15 mid-data-plane — harness artifact, not a defect witness); attempt 2 ran to
completion. Private block verified clean (no orphaned beams) between attempts and after.

Orchestrator: `[azb20] 6 FAIL/SUBSTRATE-NEVER-UP cells` — recipe exit **1** (unchanged).

| probe | control | data | integration | identity |
|---|---|---|---|---|
| arm-resources | 1 (RG get-after-delete → 500) | 3 | 2 | 2 |
| resourcegraph | 1 (RouteNotFound 404) | 3 | 2 | 2 |
| keyvault | 1 (12 FAIL 503 RouteNotReady) | 2 | 2 | 2 |
| secrets | 1 (node crash) | 2 | 2 | 2 |
| appconfig | 2 | 3 | 2 | 2 |
| blob | 2 | **0** (15/15) | 2 | 2 |
| cosmos | 2 | **1** (19/20 — see below) | 2 | 2 |
| ledger | 2 | **0** (7/7) | 2 | 2 |
| eventgrid/eventhubs/sentinel | 2 | 2 | 2 | 2 |
| HEADER-AUDIT | **1** (34 violations) | **0** (0 violations) | - | - |

## Per-cell verdicts (the six GAP cells)

1. **header-audit x-ms-request-id (GAP-AZB20-3)** — **STILL OPEN (FAIL)**.
   Control header audit exit 1: 34 violations, every one a 500-class response missing
   `x-ms-request-id` (`PUT .../resourcegroups/ts1-sdk-rg → 500 missing x-ms-request-id`).
   The router's `arm_request_id` plug uses `register_before_send`
   (`lib/smalt/arm_gateway/router.ex:101-111`); crash-rendered 500s never reach it.
   The gap-fix diffs did not touch this path.

2. **ARM control 500s (GAP-AZB20-2)** — **STILL OPEN (FAIL)**. Witnessed
   `arm-resources` probe: `resourcegroup get-after-delete -> expect 404` got 500
   (`RestError: statusCode=500`). New routes (RG PATCH / resourceGroups/:rg/resources /
   /locations) exist in the diff but the root cause is unchanged: ARM writes dereference
   data-plane Store tables absent on a control-only boot.

3. **ARG 404 (GAP-AZB20-6)** — **STILL OPEN on control (FAIL)**. `resourcegraph` probe on
   control: `rg.bad KQL -> expected 400, got 404 RouteNotFound`. The ResourceGraph route
   family exists at `lib/smalt/egress_router.ex:1337` (pre-existing, receipted by
   `i29-arg-route-family.md`) but is not mounted on the control-only plane; the data-plane
   cell was HARNESS-SKIP (STS 404) so the route went unexercised there this run.

4. **cosmos bulk partition-key (GAP-AZB20-7)** — **CLOSED (PASS)**. Full standalone
   20-probe witness against a `MIX_ENV=test` data-plane boot on the private block
   (egress 39445): `bulk upsert 3 ops (single partition) — 3/3 ok; statuses 201,201,201`
   and `bulk upsert cross-partition (3 pks) — 3/3 ok`. Both matrix runs agree (orchestrated
   run 2: same two lines PASS, 19/20). Non-bulk surface clean: CRUD, etag CAS 412, upsert
   200/201 semantics, query, partition-scoped query, 120-doc seed, pagination
   continuation, list.
   **Residual (new finding, not the gap's family)**: 1/20 FAIL — the probe's
   query-whitelist check expects a non-whitelisted WHERE-clause query refused 400 but it
   is ADMITTED (`query(WHERE-clause) refused 400 — NO ERROR — non-whitelisted query
   ADMITTED`). Distinct from GAP-AZB20-7; needs its own KD/triage decision.
   Also: GAP-AZB20-9 (standalone-rerun 401 MalformedBearerHeader transient) is now
   explained — a `MIX_ENV` skew. Standalone probe against a dev-env boot 401s at
   `db.createIfNotExists`; against `MIX_ENV=test` it runs clean. Harness property, not a
   substrate defect.

5. **KV control 401/503 (GAP-AZB20-5)** — **STILL OPEN (FAIL)**. `keyvault` probe on
   control: 15 probes → 12 FAIL, all `503 RouteNotReady` (rotation policy, rotate, delete
   LRO, crypto block) + purgeDeletedKey 404. The diff's `update_key_properties` +
   `patch /keys/:name[/:version]` routes land on the egress (data) plane, not the
   control-only surface the cell exercises.

6. **(sixth cell, blob)** — **PASS**: blob probe 15/15 on data, including
   `delete mutable container 202` (the new `delete_container` cascade, WORM-checked).

## Root-cause note

Cells 1/2/3/5 share one root: control-only boots answer surfaces whose backing Store
tables / route mounts live on the data plane. The gap-fix diffs added routes and handlers;
they did not change the control-plane mounting story. Closing them is the planes lane's
GAP-AZB20-1/4 design decision (storage attachment / route mount), not more route surface.

## Replay

```bash
MIX_BUILD_ROOT=_build-ft-az20 mix test test/data_plane/ test/arm/ test/wire/   # 500/0
MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk                                    # exit 1, ~35 min
MIX_ENV=test AZB20_PLANES=data AZB20_SB_KEY=<b64> SMALT_TLS_CERTFILE=$PWD/.smalt/tls/dev-cert.pem \
  SMALT_TLS_KEYFILE=$PWD/.smalt/tls/dev-key.pem mix run --no-start --no-halt \
  test/sdk-full/azb20/boot_plane.exs          # poll 39445
SMALT_TS_EGRESS=http://127.0.0.1:39445 node test/sdk-full/cosmos.probe.mjs     # 19/20, 1 whitelist FAIL
```

Artifacts: `tmp/azb20/matrix.json` (45 rows), `tmp/azb20/capture-{control,data}.jsonl`,
`/tmp/az20-verify-azsim-sdk2.log`, `/tmp/az20-data-boot2.log`. Build root
`_build-ft-az20` left for coordinator reclaim. Private block verified clean after all runs
(no orphaned beams; no kills of other lanes' listeners).
