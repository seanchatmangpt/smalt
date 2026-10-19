# i29-stress-fresh2 — stress tier rerun post 0009df3

- **Date**: 2026-10-18
Context: solo(MIX_BUILD_ROOT=_build-ft-str3 mix test --include stress)
- **Subject**: smalt @ main 0009df3, `/Users/sac/smalt`, build root `_build-ft-str3` (not deleted)
- **Standing**: PARTIAL_ALIVE — stress tier executes end-to-end; 6 failures / 2760 tests, no compile abort

## Prior blocker

`BLOCKED[BUILD_BROKEN_TEST_COMPILE]` on `:sovereign_gap` compile abort (receipt
`i29-stress-fresh.md`) is RESOLVED at 0009df3: this run had **zero compile
errors** and zero `sovereign_gap` mentions in the full log. Per W672 law, prior
attempts were 0 tests executed, not failures — this is the first real
stress-tier census from a green build.

## Command + embedded output

```
MIX_BUILD_ROOT=_build-ft-str3 mix test --include stress
```

Summary line (verbatim):

```
1 doctest, 7 properties, 2760 tests, 6 failures (61 excluded)
Finished in 518.2 seconds (21.8s async, 496.4s sync)
```

A first attempt completed with exit 0 reported by the wrapper but the tail
window lost the summary; a second full-capture run is the receipted run above
(wrapper exit 2 with 6 failures). No compile abort in either run.

## Failures (6)

1. `SmaltTest.Azsim.DetsRecoveryTest` — "graphlaw/WasmEngine killed mid-request:
   caller receives :engine_unavailable as HTTP 503 typed body, nothing admitted"
   (test/azsim/dets_recovery_test.exs:237) — `eventually("WasmEngine restarted
   after kill"): not satisfied within 5000ms (after 28 pass(es)) — last value:
   :down`. One-line cause: engine restart poll timed out at 5s (engine still
   :down; possible load-induced under concurrent lane traffic).
2. `Smalt.RegistryReplayIdentityTest` — "pack lock digest matches the live pack
   checkout" (test/smalt_registry_replay_identity_test.exs:61) — `:lock_drift`,
   lock pins 43c15edb…, live pack computes a454f2f0…; re-pin via
   `mix ggen_igniter.pack.lock --path ../ggen-marketplace/packs/smalt-substrate-pack --pack smalt-substrate-pack`.
3. `Smalt.Wire.EgressWireTest` — "Key Vault: release with valid CVM attestation
   returns released key material over the wire" (test/wire/egress_wire_test.exs:150)
   — `assert attest.status == 200` failed, left 503 / right 200.
4. `Smalt.ConfigReplayIdentityTest` — "pack lock digest matches the live pack
   checkout" (test/config_replay_identity_test.exs:75) — same `:lock_drift` as
   failure 2 (shared live-pack drift).
5. `Smalt.CanonicalProjectionTest` — "generated artifact drift fence
   docs/capabilities.json equals rendered json/0"
   (test/canonical_projection_test.exs:134) — `docs/capabilities.json is stale
   vs Registry truth`; regenerate with
   `mix run -e 'Smalt.Projection.Canonical.write()'`.
6. `SmaltTest.Azsim.TopologyTest` — "ARM resource PUT emits ResourceWriteSuccess
   to integration plane" (test/azsim/topology_test.exs:141) —
   `assert body["data"]["resourceUri"] == uri`, left
   `/subscriptions/sub-1/.../Microsoft.ServiceBus/namespaces/sbq-new-ns` vs
   right `/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/azb10sa26052`;
   event observation raced/missed the expected resource.

## Classification

- Real test failures: 6 (list above), 2754 passing (2760 - 6), 0 compile aborts.
- Failures 2 and 4 are one root cause (pack-lock drift vs live
  ggen-marketplace pack).
- Failure 5 is a stale generated artifact (regeneration, not code).
- Failures 1, 3, 6 are behavioral and need individual repair lanes.
- Machine was under concurrent load (multiple other lanes' mix/beam processes
  active during the run); timing-sensitive failures (1) carry that caveat.
