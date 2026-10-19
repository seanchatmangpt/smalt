# Receipt: AZB-20 — Unmodified Microsoft SDK interop per plane

- **Ticket**: AZB-20 (`docs/jira/v26.10.18/azsim-burn/TICKETS.md`, binding)
- **Standing**: PARTIAL_ALIVE — per-plane matrix + header audit executed for real; accept `just azsim-sdk` exit 0 NOT met (6 FAIL-class cells stand as open typed gaps)
Context: pair(test/lro_test.exs, test/azsim/topology_test.exs — 45 tests) + slice(test/amqp — 331 tests) + solo(test/sdk-full/azb20/run.mjs per-plane orchestrator)
- **Subject SHA**: `467d7d13ccbf83ff0ab51a828a9781b165cec847` (shared checkout; other lanes hold unrelated in-flight files — untouched by this lane)
- **Date**: 2026-10-18
- **Commit**: not minted (no-git constraint per dispatch)

## Method

For each plane in {control, data, integration, identity}: boot the substrate with ONLY that
plane (`AZB20_PLANES=<plane>` via `test/sdk-full/azb20/boot_plane.exs`). The boot script
mirrors `config/runtime.exs` semantics exactly: `Config.Reader.read!` of the selected
planes' `config/env/az_prod_<plane>.exs` profiles, then private-port overrides applied
AFTER the profile import (port single-source law preserved). Private block 39443-39475,
lsof-verified free before every boot; the canonical ports were held by another lane's
substrate for the whole session and were never touched (no eviction). The 11 probes in
`test/sdk-full/*.probe.mjs` are byte-UNMODIFIED (unmodified-SDK law) — per-plane env
remaps only. HTTP legs of the SDK probes ride a TLS-terminating recording proxy
(`azb20/recording-proxy.mjs`, dev CA) that captures every response and audits the header
contract; AMQP legs go direct. Falsifier + anti-vacuity below.

## Landed

| File | Change |
|---|---|
| `justfile.d/14-sdk-matrix.just` | new `azsim-sdk` recipe (lane-owned file) |
| `test/sdk-full/azb20/boot_plane.exs` | NEW: per-plane boot (runtime.exs-equivalent profile import + private ports) |
| `test/sdk-full/azb20/run.mjs` | NEW: orchestrator — per-plane boot, socket witness, 11 unmodified probes x 4 planes, header audit, `tmp/azb20/matrix.json` |
| `test/sdk-full/azb20/recording-proxy.mjs` | NEW: TLS-terminating recording proxy + per-plane header-audit rules |
| `test/sdk-full/azb20/strip-rid-court.sh` | NEW: anti-vacuity court (below) |
| `lib/smalt/arm_gateway/lro_sweeper.ex` | Disclosure 1: `run_pass` no-ops while `:smalt_operations` ETS table is absent |
| `lib/smalt/messaging/amqp/sweeper.ex` | Disclosure 1: `run_pass` no-ops while `:smalt_sb_locks`/`:smalt_sb_messages` are absent |

Disclosure 1 (cross-lane, planes-lane files): before this lane's guards,
`SMALT_PLANES=control` and `SMALT_PLANES=integration` boots CRASH-LOOPED the whole
application and exited — the LRO Sweeper (control) and Amqp.Sweeper/QueueStore
(integration) tick paths dereference data-plane Store-owned ETS tables. Per-plane boots
had never been exercised live before AZB-20 (AZB-05..08 receipts witnessed config-level
loads only). The guards make the sweep passes no-op until the tables exist; the storage
attachment question (should control/integration own or attach a Store) stays OPEN for the
planes lane. Post-fix regression witness: `mix test test/lro_test.exs
test/azsim/topology_test.exs` → 45 tests, 0 failures; `mix test test/amqp` → 331 tests,
0 failures (45 excluded) — both under `MIX_BUILD_ROOT=_build-lane-azb20`.

## Real output — final interop matrix (2026-10-18, tmp/azb20/matrix.json, 46 rows)

Exit legend: 0=PASS · 1=FAIL (typed divergence witnessed) · 2=PLANE-DOWN (expected:
the surface's plane was not selected) · 3=HARNESS (probe harness hit a dead dependency
surface — e.g. STS mint 404 — after its own preflight passed)

| probe (unmodified MS SDK probe) | control | data | integration | identity |
|---|---|---|---|---|
| arm-resources.probe.mjs (@azure/arm-resources) | 1 | 3 | 2 | 2 |
| resourcegraph.probe.mjs (@azure/resourcegraph) | 1 | 3 | 2 | 2 |
| keyvault.probe.mjs (@azure/keyvault-keys) | 1 | 2 | 2 | 2 |
| secrets.probe.mjs (@azure/keyvault-secrets) | 1 | 2 | 2 | 2 |
| appconfig.probe.mjs (@azure/app-configuration) | 2 | 3 | 2 | 2 |
| blob.probe.mjs (@azure/storage-blob) | 2 | **0** | 2 | 2 |
| cosmos.probe.mjs (@azure/cosmos) | 2 | 1 | 2 | 2 |
| ledger.probe.mjs (Confidential Ledger REST) | 2 | **0** | 2 | 2 |
| eventgrid.probe.mjs | 2 | 2 | 2 | 2 |
| eventhubs.probe.mjs (@azure/event-hubs) | 2 | 2 | 2 | 2 |
| sentinel.probe.mjs | 2 | 2 | 2 | 2 |
| HEADER-AUDIT (recording proxy) | **FAIL** (29 violations, 500-class) | **PASS** (2 responses, 0 violations) | — | — |

Socket witnesses per plane (from run output): control {arm,armTls}; data {egress};
integration {amqp,eh}; identity {} (no socket of its own — see GAP-AZB20-4).

## Typed gap register (all witnessed this session, all OPEN)

- **GAP-AZB20-1 (control/integration boot dependency)** — fixed crash-loop, open design
  question. `SMALT_PLANES=control` / `=integration` crash-looped the application
  (LRO Sweeper → `:smalt_operations` missing; Amqp.Sweeper → QueueStore `lock_sweep` →
  `:smalt_sb_*` missing; logs: `test/sdk-full/.logs/azb20-{control,integration}-substrate.log`).
  Substrate logs were captured in `test/sdk-full/.logs/azb20-*-substrate.log` per plane.
  Guarded as disclosed; the storage-attachment decision belongs to the planes lane.
- **GAP-AZB20-2 (control-only ARM writes fail without the data plane)** — on the
  control-only boot, ARM resource writes 500: witnessed `PUT /subscriptions/.../resourcegroups/azb20wrg?api-version=2021-04-01`
  → `HTTP/1.1 500 Internal Server Error` (ARM router reads/writes
  `:smalt_resource_groups` via the data-plane Store). arm-resources probe legs:
  listByResourceGroup 404 pagination failure, tags PATCH 404, LRO deletes 500.
  Same-root witness from the matrix run: RG PUT 500s in capture-control.jsonl.
- **GAP-AZB20-3 (500s bypass the x-ms-request-id plug)** — every 500-class response on
  the control plane leaves WITHOUT `x-ms-request-id` (the crash-rendered 500 never
  reaches the router's request-id plug). Witnessed 29/29 audit violations, all
  `... -> 500 missing x-ms-request-id` (capture-control.jsonl). This is why the
  control header audit FAILs; it is the same defect family as GAP-AZB20-2, observed at
  the header-contract level the ticket mandates.
- **GAP-AZB20-4 (identity plane has no socket of its own)** — `SMALT_PLANES=identity`
  boots zero plane listeners (`IdentitySupervisor children: []`); STS/KeyVault ride the
  control plane's TLS twin and the data plane's egress router. All 11 identity-plane
  cells are PLANE-DOWN. Either the identity plane gains its own listeners or the matrix
  codifies "identity is a profile, not a topology seat".
- **GAP-AZB20-5 (KV/secret surfaces not ready on control-only boot)** — witnessed:
  bearer-authenticated `PUT /secrets/azb20w1?api-version=7.4` on the control TLS twin →
  `503 {"error":{"code":"RouteNotReady"}}`; unauthenticated → 401 (strict-bearer
  challenge); the secrets probe collapses with `/secrets/... could not be found`.
  The keyvault probe: 15 probes → 12 FAIL / 3 PASS/DIVERGENCE (rotation/rotate/delete/
  crypto route families missing on the control-only surface). KV surfaces depend on
  identity-plane readiness + Store.
- **GAP-AZB20-6 (ResourceGraph route family absent)** — every
  `/providers/Microsoft.ResourceGraph/resources` call → 404 `RouteNotFound`
  (resourcegraph probe exit 1 on control; exit 3 on data: STS 404).
- **GAP-AZB20-7 (@azure/cosmos bulk upsert)** — data plane 17/20 PASS; the 3 failures are
  one defect family: `Bulk request errored with: Partition key provided in the header
  doesn't match the partition key of the document.` (single-partition and
  cross-partition). Everything else (CRUD, pagination continuation, seeding 120 docs,
  database/container list) passes over the real SDK wire. Non-bulk cosmos is SDK-clean.
- **GAP-AZB20-8 (attach-mode probe preflight requires the full port set)** — the
  eventgrid/eventhubs/sentinel probes' EXTERNAL attach preflights dial ALL of
  {arm, egress, amqp, eh}; on an integration-only boot (amqp+eh up, witnessed) they exit 2
  before dialing AMQP. Harness limitation, not an emulator defect; AMQP listeners
  witnessed open on 39472/39473. To exercise the AMQP wire per-plane the probes need an
  attach mode that dials only its own surface (probe-capital change — not done in this
  lane; unmodified-probe law).
- **GAP-AZB20-9 (cosmos orchestrated-cell transient, unreproduced)** — in the
  orchestrated run the data/cosmos cell exited 1 with
  `401 MalformedBearerHeader`; a direct rerun against the same plane boot gave the stable
  17/20 result (GAP-AZB20-7) and anonymous-mode curls of `/dbs` return 200. Not
  reproduced twice; recorded per honesty law. Suspect: probe-internal retry/race —
  falsifier for a follow-up lane.

## Accept — status

- Ticket accept: `just azsim-sdk` exit 0 — **NOT MET**; the recipe currently exits 1
  while GAP-AZB20-2/3/6/7 are open (run output: `[azb20] 6 FAIL/SUBSTRATE-NEVER-UP cells
  (typed gaps — see tmp/azb20/matrix.json)`). Cells that are typed refusals
  (PLANE-DOWN/HARNESS) do not fail the run by design.
- Header audit 100% coverage — **MET on data, FAILED on control with witnessed cause**
  (GAP-AZB20-3): data plane 2/2 responses clean; control plane 29 violations, every one a
  500-class response missing `x-ms-request-id`.

## Falsifier (witnessed)

- "Any SDK requires a patch/monkeypatch/env hack beyond endpoint + CA trust" — NO SDK
  needed a patch: all 11 probes ran byte-unmodified against all 4 planes (env remaps
  only; NODE_EXTRA_CA_CERTS for the dev CA is endpoint+CA trust, permitted).
  The failures above are wire/behavior divergences, not SDK hacks.
- Per-plane boots really boot: socket witness per plane in run output
  (control {arm,armTls}, data {egress}, integration {amqp,eh}, identity {}).

## Anti-vacuity (witnessed)

`test/sdk-full/azb20/strip-rid-court.sh` (SHIM-COURT AZB-20):
BASELINE sha256 `4a4511e9284200ea52a26ed8a1da19ecbab5458cec509dca28432d7c3a21bf32` →
SHIM strips `put_resp_header(conn, "x-ms-request-id", request_id)` from the ARM router
(marker `SHIM-COURT AZB-20`) → AFTER: header audit FAILED with 3 missing-x-ms-request-id
violations (`tmp/azb20/antivacuity-court.log`) → RESTORE byte-exact (same sha256).
A court that cannot flip is FAIL; this one flips.

## Replay

```bash
just azsim-sdk                 # full per-plane matrix + header audit (~20 min)
bash test/sdk-full/azb20/strip-rid-court.sh   # anti-vacuity court
```

Artifacts: `tmp/azb20/matrix.json` (46 rows), `tmp/azb20/capture-{control,data}.jsonl`,
`tmp/azb20/antivacuity-court.log`, `test/sdk-full/.logs/azb20-*-substrate.log`.

## Disclosures

- `MIX_BUILD_ROOT=_build-lane-azb20` used throughout; coordinator should reclaim it at
  integration (`just lane-clean`).
- The tree is shared; concurrent lanes' in-flight files (identity/sts_gate.ex, dr_scenarios_test.exs, pplan_test.exs, test/support/lifecycle.ex, docs) are NOT this lane's.
- No git actions taken (per dispatch).

---

## Re-run 2026-10-18 (AZB-20 interop re-run lane, HEAD `efc8d92778f36ca7af623e3412c373b6f5ff674d`)

Context: solo(test/sdk-full/azb20/run.mjs orchestrator, 2 full matrix runs)
- **Standing**: PARTIAL_ALIVE (unchanged) — accept `just azsim-sdk` exit 0 **NOT MET**; 6 FAIL-class cells reproduce exactly at `efc8d92`.
- **Subject SHA**: `efc8d92778f36ca7af623e3412c373b6f5ff674d` (≥ ticket floor; prior receipt was at `467d7d1`, so re-run required — not green).

### Method / environment

Private block 39443-39475 lsof-verified free before run 1; canonical ports (colima-held)
never touched, no evictions, no kills. Fresh build root `MIX_BUILD_ROOT=_build-lane-azb20r`.
All 11 probes byte-unmodified; env remaps + dev-CA trust only.

### Real output — run 1 (cold build root, ~22:50-23:13)

Control plane: **SUBSTRATE-NEVER-UP** — the cold compile of `_build-lane-azb20r` exceeded
the boot deadline (log `test/sdk-full/.logs/azb20-control-substrate.log` ends mid-compile,
"Compiling 2 files (.erl)"); 11 cells exit 2 SUBSTRATE-NEVER-UP. Run 1 is a harness
warm-up witness, not a plane defect witness. Data/integration/identity cells identical
to run 2.

### Real output — run 2 (warm, definitive, ~23:16-23:40)

| probe | control | data | integration | identity |
|---|---|---|---|---|
| arm-resources | 1 | 3 | 2 | 2 |
| resourcegraph | 1 | 3 | 2 | 2 |
| keyvault | 1 | 2 | 2 | 2 |
| secrets | 1 | 2 | 2 | 2 |
| appconfig | 2 | 3 | 2 | 2 |
| blob | 2 | **0** | 2 | 2 |
| cosmos | 2 | **1** | 2 | 2 |
| ledger | 2 | **0** | 2 | 2 |
| eventgrid/eventhubs/sentinel | 2 | 2 | 2 | 2 |
| HEADER-AUDIT | **1** (26 violations) | **0** (2 responses, 0 violations) | - | - |

Orchestrator: `[azb20] 6 FAIL/SUBSTRATE-NEVER-UP cells (typed gaps — see tmp/azb20/matrix.json)` — recipe exit 1.

### Verdict per gap (all still OPEN at efc8d92)

- **GAP-AZB20-2** REPRODUCED: control ARM writes 500 (`PUT .../resourcegroups/ts1-sdk-rg → 500 missing x-ms-request-id`).
- **GAP-AZB20-3** REPRODUCED: control header audit FAIL — 26/26 violations, all 500-class missing `x-ms-request-id` (was 29, same family).
- **GAP-AZB20-5** REPRODUCED: KV/secrets probes exit 1 on control-only boot.
- **GAP-AZB20-6** REPRODUCED: resourcegraph 404 RouteNotFound family.
- **GAP-AZB20-7** REPRODUCED: cosmos bulk-only failure — data plane otherwise PASS; witness: `Bulk request errored with: Partition key provided in the header doesn't match the partition key of the document.` (single- + cross-partition, `code=undefined body=""`).
- GAP-AZB20-1/4/8 unchanged (harness/plane-topology, not exercised differently).
- GAP-AZB20-9 (cosmos orchestrated transient) — not reproduced this session; data/cosmos gave the stable bulk-only exit 1 both runs.

### Accept status

- `just azsim-sdk` exit **1** (6 FAIL-class cells).
- Header audit: data 0 violations (PASS); control FAIL with witnessed cause (GAP-AZB20-3).
- Falsifier still holds: no SDK needed a patch/monkeypatch beyond endpoint + CA trust.

### Replay

```bash
MIX_BUILD_ROOT=_build-lane-azb20r just azsim-sdk   # exit 1, ~25 min (cold: +10 min compile)
```
Artifacts: `tmp/azb20/matrix.json` (45 rows, run 2), `/tmp/azb20-rerun2.log`,
`test/sdk-full/.logs/azb20-*-substrate.log`. Build root `_build-lane-azb20r` left for
coordinator reclaim (`just lane-clean`).
