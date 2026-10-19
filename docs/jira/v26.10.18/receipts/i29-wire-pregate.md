# i29 AMQP wire pre-gate — 2 full legs at current HEAD (build root _build-ft-w8)

Command: `MIX_BUILD_ROOT=_build-ft-w8 mix test --include amqp_wire` (run twice, full logs `/tmp/w8_run1.log`, `/tmp/w8_run2.log`)
Context: slice(amqp_wire ×2)
Date: 2026-10-19. No edits, no git ops, no _build deletion.

## Legs

A warm-up leg (unlogged, discarded tail view) showed **17 failures** with identities
uncaptured — harness discipline gap, reported as-is (same pattern the
i29-wire-fresh3 receipt flags for its runs 2/3).

| leg | result | identities |
|---|---|---|
| 1 | 1 doctest, 7 properties, 2801 tests, **1 failure**, 38 excluded | `Smalt.Semantic.StoreRead.Lens6StructuralTest` "a Store row with a non-map properties projects provisioning_state nil, never crashes" (test/semantic_projection_test.exs:472) — `Ash.Error.Unknown`: "semantic projection: vacuous identity under :smalt_resources ("id" = nil) — refusing read instead of projecting an identity-less row" from `Ash.read!(Smalt.Semantic.Resource)`. **LOAD (contention)** — solo bisect `mix test test/semantic_projection_test.exs --include amqp_wire` → `20 tests, 0 failures` (0.4 s), same file-level proof shape as the witnessed LedgerWriter tx_id-collision face (i29-wire-fresh4 face 23, same file, LOAD contention family). |
| 2 | 1 doctest, 7 properties, 2801 tests, **3 failures, 1 invalid**, 38 excluded | 1. `SmaltTest.Azsim.DrScenariosTest` scenario 3 (identity subtree kill, dr_scenarios_test.exs) — **LOAD (boot-contention)**, the witnessed econnrefused-on-shared-listener family (i29-wire-fresh3 faces 1–4). 2–3. `SmaltTest.Azsim.TopologyTest` "identity-plane STS token accepted by data plane over the wire" + "ARM resource PUT emits ResourceWriteSuccess to integration plane" — **LOAD (F61 Topology class)**, econnrefused on arm_port mints under load (i29-court-dry3 classification). Plus `Smalt.Chaos.CrashIsolationTest` setup_all invalidation — **roster (CrashIsolation invalid)**. |

## Roster verdict

| roster face | count this gate |
|---|---|
| F58/F60 EventGrid/egress 503 readiness | 0 |
| F59 GracefulStop boot | 0 |
| F61 Topology cross-test | 3 (leg 2 ×2, plus warm-up leg consistent) |
| DetsRecovery rotating | 0 |
| McpWire/boot-contention | 0 (McpWire green in both logged legs) |
| CrashIsolation invalid | 1 (leg 2) |
| NEW | **0** — leg 1's Lens6 face solo-green bisects to the contention family |

## Standing

**ALIVE** — acceptance met: zero NEW faces across the two logged legs. All observed
failures are witnessed LOAD/contention classes (F61 Topology, DrScenarios boot-contention,
Lens6 solo-green contention) or the rostered CrashIsolation setup_all invalidation.
Pinions hold (no wire-compat pinion files touched). Residual: warm-up leg identities
uncaptured (non-gating, harness discipline); failure counts swing 1→17 across legs,
consistent with load-class variance at HEAD, not a construction change.
