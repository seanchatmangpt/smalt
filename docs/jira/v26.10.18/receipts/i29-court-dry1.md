# i29 court-x2 DRY-RUN leg 1 — full `mix test` under load

- Date: 2026-10-18, repo /Users/sac/smalt, build root `_build-ft-court1` (no rm, no edits, no git).
- Context: solo(MIX_BUILD_ROOT=_build-ft-court1 mix test) — two full runs + solo reruns of failing tests.
- Machine: Darwin 25.2.0 (arm64); tree busy with concurrent lanes (quiet-check deliberately not run — dry-run leg).

## Run 1
`MIX_BUILD_ROOT=_build-ft-court1 mix test` — **1 doctest, 7 properties, 2728 tests, 1 failure (93 excluded)**, 182.4s.
Failure detail lost to output truncation (tail-only capture); run 2 re-captured in full.

## Run 2
`MIX_BUILD_ROOT=_build-ft-court1 mix test` — **1 doctest, 7 properties, 2728 tests, 4 failures (93 excluded)**.

1. `test graphlaw/WasmEngine killed mid-request: caller receives :engine_unavailable as HTTP 503 typed body, nothing admitted (SmaltTest.Azsim.DetsRecoveryTest)` — test/azsim/dets_recovery_test.exs:237 —
   `eventually("WasmEngine restarted after kill"): not satisfied within 5000ms (after 30 pass(es)) — last value: :down`.
   **LOAD** — the known rotating DetsRecovery WasmEngine face; PASSES in solo rerun.
2. `test generated artifact drift fence docs/capabilities.json equals rendered json/0 (Smalt.CanonicalProjectionTest)` — test/canonical_projection_test.exs:134 —
   `docs/capabilities.json is stale vs Registry truth` (`on_disk != Canonical.json()`).
   **NOT LOAD** — reproduces in solo rerun (real drift face, content). Likely from in-flight `lib/` edits vs the generated `docs/capabilities.json` not regenerated; this lane performed no edits.
3. `test GET list is topic-scoped (Smalt.EventGridConformanceTest)` — test/eventgrid_conformance_test.exs:415 — `assert resp.status == 200`, left 503, right 200.
   **LOAD** — PASSES in solo rerun (503 under concurrent boot churn).
4. `test ARM resource PUT emits ResourceWriteSuccess to integration plane (SmaltTest.Azsim.TopologyTest)` — test/azsim/topology_test.exs:141 —
   `assert body["data"]["resourceUri"] == uri` — left `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/fr6-rg3/providers/Microsoft.Storage/storageAccounts/fr6acct3` (another test's fixture) vs expected `/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/azb10sa28099`.
   **LOAD** — cross-test contamination under 20-lane load; PASSES in solo rerun.

## Solo rerun
`MIX_BUILD_ROOT=_build-ft-court1 mix test test/azsim/dets_recovery_test.exs:237 test/canonical_projection_test.exs:134 test/eventgrid_conformance_test.exs:415 test/azsim/topology_test.exs:141` — **4 tests, 1 failure** — only the `CanonicalProjectionTest` drift face persists.

## Verdict
**COURT-DRY-1 NOT-GREEN**: 3/4 failures are LOAD-class (all pass solo); 1 real content face — `docs/capabilities.json` drift vs Registry truth, reproducible solo. A real (non-LOAD) face is present, so GREEN-UNDER-LOAD cannot be claimed. Surface the drift face now; not repaired (no-edit lane).
