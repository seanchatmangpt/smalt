# v26.10.29 — window handoff (from the Windows dev box, mid-agent-wave)

Written 2026-10-29 as a laptop-switch handoff. Read this before anything
else in this directory. Prior window state: `docs/jira/v26.10.28/`
(map, 18 tickets, receipts r1–r6; tickets T-03/05/09/13/17/18 CLOSED).

## where the tree stands (commit at handoff time)

`main` through `3feb1cb` is pushed and clean. On top of that, **ten
code-complete-but-unintegrated ticket lanes were written by a parallel
agent wave on the dev box** and are being committed here as they land
(some files may land in a follow-up commit after this one — see
"in-flight inventory"). Everything is CODE-COMPLETE + ticket-stamped +
receipted; NONE of the new courts have been executed yet. Integration
is the next window's first job.

## closed this window (receipted, pushed)

| ticket | receipt | note |
|---|---|---|
| T-03 | r3-era commit 474518c | eventgrid MCP tools (33 tools) |
| T-05 | r4, r5, r6 (688ece4, 3308021, 688ece4) | KQL bin/join/mv-expand/cross-workspace, full court set 25/25 |
| T-13 | r1 (fba0105) | tofu 1.13.2 = terraform 1.17.0 plan parity |
| T-17 | 474518c | snapshot-delete gate (attribute-order root cause) |
| T-18 | 474518c | blob content-type serving |
| T-09 | r2 | epoch machinery already shipped (GAP-A2-02); wire probe outstanding |
| T-04 | r7 + upstream | upstream AppConfigRoutes/AppConfigEvents superseded our hunks; receipt + court merged via 3feb1cb |

## the ten in-flight lanes (file inventory + integration checklist)

Integration order matters: compile AFTER all dep promotions, then run
courts, then apply nothing else. Per-lane details live in each receipt
(docs/jira/v26.10.28/receipts/r8..r17) — this is the consolidated
checklist:

1. **Dep promotions first** (mix.exs + `mix deps.get`):
   - ADD `{:cachex, "~> 4.0"}` (T-06 — new dep, engine does not compile without it)
   - PROMOTE transitive → direct (already in deps/, compiled): `sweet_xml`, `finch`, `yaml_elixir` (exact `~>` versions: match deps/ or mix.lock; T-07 XML + HTTP, T-01 task YAML)
2. **Wiring patches** (each receipt carries the exact lines):
   - `arm_gateway/router.ex`: mount the four pass-through provider routers BEFORE :match — `AcrRouter` (r14), `FunctionsRouter` (r13), `ResourceHealthRouter` (r12), `ContainerGroupsRouter` (r17), + APIM gateway (r16)
   - `application.ex`: RedisListener child spec gated on `:redis_enabled` default false (r15)
3. **Courts to run** (all under `test/integration/`): acr_test, functions_test,
   resource_health_test, container_groups_test, apim_test, azure_cache_test,
   seed_test, sb_delivery_test, chaos_injectors_test, plus the pre-existing
   parity_lane_wire_test (8/8) and appconfig_events (upstream's).
4. **Known integration risks** (from the agent wave's own notes):
   - T-08: if sb_delivery needed a NEW ETS table, `Smalt.StoreTables` must
     register it (check r8's StoreTables note)
   - T-06: Cachex child start order vs Store init; connection-string output
     is an honest BEAM-native accessor map, NOT a redis endpoint (deliberate
     divergence, user direction 2026-10-29)
   - T-12/T-14 share the chaos-flag → resource-health coupling: T-12 emits
     typed config keys; T-14 exposes `ResourceHealth.set_unavailable/2` /
     `set_available/1` as the coupling API — wire T-12 flags to call it
   - T-10: registry-credential validation expects ACR store rows (T-01
     lands them — run T-01 court first or seed a registry row)
5. **Baseline guard**: offline `mix test` must return to the
   7-failure pre-existing baseline (this box last measured 131/140 with
   two load-class flakes that pass solo); wf8 python court 4/4 needs
   `SMALT_PY_EGRESS` + the running substrate.
6. **T-16 (chained DLQ)** starts only after T-08's court is green
   (it chains T-08's DLQ).

## upstream refresh (IMPORTANT for the other laptop)

The `gl28-2` upstream wave (merged via 3feb1cb) already landed surfaces our
v26.10.28 parity map lists as gaps: **Table Storage**, blob CORS/soft-delete,
EH checkpoint store / capture / schema registry / throttling, Kafka +
AMQP-WebSocket bridges, managed HSM, Cosmos query metrics/feeds/authz.
`parity/COVERAGE_VS_TOPAZ.md`, the roadmap map, and tickets T-05-adjacent
notes are stale on the upstream side — refresh before citing gaps.

## environment deltas on the dev box (not in git)

- scoop toolchain: `tofu` 1.13.2 installed; `cachex` NOT yet a dep
- python venv OUTSIDE repo: `%USERPROFILE%\dev\tools\pyaz`
  (azure-storage-blob 12.31, azure-storage-queue 12.18, pytest 9.2)
- Azure dev cert trusted in USER Root store (certutil; see r1)
- services: smalt pinned ports / Azurite 10000-10002 with
  `--skipApiVersionCheck` — restart commands in
  `docs/how-to/how-to-run-on-windows.md`
- SDK tree: `%USERPROFILE%\dev\tools\azsdk` junctioned as
  `parity/node_modules` (recreate with mklink after clone)

## ticket ledger after this commit

CLOSED: T-03, T-04, T-05, T-09 (impl), T-13, T-17, T-18.
CODE-COMPLETE awaiting integration run: T-01, T-02, T-06, T-07, T-08,
T-10, T-11, T-12, T-14, T-15. NOT STARTED: T-16 (blocked on T-08),
T-07-adjacent APIM gateway wiring (r16 patch).

## UNDOCKED — what is still undone (read this first on the other laptop)

All ten agent lanes landed and are pushed, but the wave ended BEFORE the
integration pass. Nothing below is optional:

1. **Deps not promoted.** `{:cachex, "~> 4.0"}` missing (azure_cache.ex is
   runtime-dead without it); `sweet_xml`/`finch`/`yaml_elixir` still
   transitive — promote to direct deps (versions: match deps/ or mix.lock),
   then `mix deps.get`.
2. **Wiring patches not applied.** Four pass-through provider routers
   (`AcrRouter`, `FunctionsRouter`, `ResourceHealthRouter`,
   `ContainerGroupsRouter`) + the APIM gateway are unwired; the single
   `plug(...)` lines are in receipts r12/r13/r14/r16/r17 (mount before
   `:match` in `arm_gateway/router.ex`). RedisListener child-spec gate is
   in r15 (config `:azure_cache_accounts`, default off — byte-identical).
3. **No court has been executed.** New courts: acr (6), seed (7),
   azure_cache (13+), apim (4+), sb_delivery (6), chaos_injectors,
   service_health (7), container_groups (7), iac_export (6), plus the
   existing 8-test parity_lane_wire + upstream AppConfigEvents court.
   The whole integration tier has NOT been compiled since the wave.
4. **Offline-suite baseline unverified** post-wave — must return to the
   7-failure pre-existing set.
5. **T-09 wire probe outstanding** (epoch = GAP-A2-02, shipped but not
   live-probed with two `@azure/event-hubs` receivers).
6. **T-16 not started** (chained DLQ; hard-blocked on T-08's court being
   green first).
7. **Known integration couplings**: T-12 flags → T-14
   `ResourceHealth.set_unavailable/2` wiring; T-10 registry validation
   expects T-01 ACR store rows (run ACR court first or seed a registry);
   T-06 needs StoreTables/DetsMirror regen note in r15; T-08 needs NO
   StoreTables change (verified).
8. **Wiring-patch collisions**: several receipts mount routers at the same
   seam (before `:match`); apply all four + APIM gateway + ResourceHealth
   in one edit, ordering irrelevant (each halts or passes through).
9. **Parity-map staleness**: upstream already shipped Table Storage, blob
   CORS/soft-delete, EH checkpoint/capture/schema-registry, Kafka,
   AMQP-WS, mHSM — refresh `COVERAGE_VS_TOPAZ.md` + the roadmap map before
   citing gaps.
10. **File-share.ex / SqlIngestRoutes / marketplace / sync routes** exist
    upstream without v26.10.28 coverage rows — new-surface census is a
    v26.10.29 task.

The dev-box session ended mid-settle; every agent file that existed at
undock IS committed and pushed (final tree was clean before this
addendum). If the agent output files contain anything newer than the last
sweep commit, they are lost — the receipts in this directory are the
authoritative record of each lane's contract.
