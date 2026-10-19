# i29 Full Offline Suite — Receipt (full-soak-c)

Context: slice(full-suite offline mix test, leg C)
Standing: PARTIAL_ALIVE

- Subject: /Users/sac/smalt @ HEAD 0009df3 (working tree; concurrent lanes in flight, none by this lane)
- Command: `MIX_BUILD_ROOT=_build-ft-fs7 mix test` (repo root), run 5 of 5, 2026-10-18 22:28–22:31 PT
- Build root: `_build-ft-fs7` (left in place for coordinator; not removed)

## Verdict

- **Compile-abort class (test/azsim/sovereign_midnight/sovereign_midnight_test.exs `/burn-evidence` require) is FIXED at HEAD.** No require error anywhere in any of the 5 runs; sovereign_midnight tests executed normally.
- No compile abort in any run. The suite ran to completion in runs 2 and 5.

## Run ledger (all real output, embeds from /tmp/i29_mixtest*.log)

| run | start | outcome | note |
|---|---|---|---|
| 1 | 22:08 | 2722 tests, 0 failures (99 excluded) | this lane's first run completed green (summary line seen at end of first invocation) |
| 2 | 22:13 | 2727 tests, 3 failures (94 excluded), exit 1 | this lane accidentally ran two suites concurrently; failures are interference-shaped |
| 3, 4 | 22:16–22:18 | boot BLOCKED: `Smalt.Store ** (EXIT) already started` | concurrent lane had in-flight edits to `lib/smalt/plane/integration_supervisor.ex` (mtime 22:13) and `lib/smalt/store_tables.ex` (mtime 22:16) — Store was double-started; cross-lane compile-freeze violation, not HEAD defect |
| 5 | 22:28 | 2728 tests, 10 failures (93 excluded), exit 1 | authoritative full run, tree quiesced ~4 min before start; machine still carried ≥5 other lanes' mix test beams (513% CPU observed) |

Run 5 summary line (verbatim):

```
Finished in 182.1 seconds (18.5s async, 163.6s sync)
1 doctest, 7 properties, 2728 tests, 10 failures (93 excluded)
```

## Run 5 failures — name / module / cause / classification

1. `Vector 3: Half-open TCP silent partition...` — Smalt.Azsim.AdversarialJoeTest, test/azsim/adversarial_joe_test.exs:121 — `{:error, :econnrefused}` connecting to the test's own listener. **Contention-class**: file passes in isolation (`mix test test/azsim/{topology,dr_scenarios,adversarial_joe}_test.exs` → `16 tests, 0 failures`, exit 0).
2-5. DrScenariosTest scenarios 1-4 (test/azsim/dr_scenarios_test.exs:279/187/232/104) — `:econnrefused` / `:gen_tcp.connect` `:badarg` on subtree-kill reconnect loops. **Contention-class**: same isolated file run above, 0 failures.
6-8. EventHubs KD-53 / R185e batch-split trio (test/amqp/event_hubs_test.exs:861/941/993) — batch split produced 1-2 events instead of 3-4. **Contention-class**: isolated rerun `mix test test/amqp/event_hubs_test.exs` → `27 tests, 0 failures (7 excluded)`, exit 0.
9. `generated artifact drift fence docs/capabilities.json equals rendered json/0` — Smalt.CanonicalProjectionTest, test/canonical_projection_test.exs:134 — `assert on_disk == Canonical.json()` → "docs/capabilities.json is stale vs Registry truth". **Fails in isolation too** (`20 tests, 1 failure`). Environment-dependent: `docs/capabilities.json` is byte-identical to HEAD (clean `git diff`, mtime 22:16:05) and `lib/smalt/registry.ex` is unmodified at 15:37 — the rendered `Canonical.json()` depends on ambient runtime state (other lanes' substrates/listeners up on the same host), so the fence is not quiescence-stable. Environment-class, not a HEAD content defect; verify with `just quiet-check` before any court.
10. `ARM resource PUT emits ResourceWriteSuccess` — SmaltTest.Azsim.TopologyTest, test/azsim/topology_test.exs:141 — asserted `resourceUri` came back as another test's corpus URI (`/subscriptions/sub-corpus/...` vs `/subscriptions/s/...`). **Contention-class**: topology_test.exs passes in the isolated azsim run (16 tests, 0 failures).

Run 5 failure-count arithmetic: 1 + 4 + 3 + 1 + 1 = 10. Nine of ten reproduce as zero-failure in isolation; one (capabilities.json drift fence) fails alone but is provenance-clean on disk.

## Cross-lane finding (for coordinator)

- At 22:13–22:16 another lane edited `lib/smalt/plane/integration_supervisor.ex` and `lib/smalt/store_tables.ex`; during that window any other lane's `mix test` on this tree boot-fails with `Smalt.Store already started`. Compile-freeze SLA breach witnessed twice (runs 3-4).
- ≥5 concurrent `mix test` beams on the shared tree (incl. `--include stress`) produce deterministic-looking failures (econnrefused, batch-split undercount, cross-test corpus bleed) that vanish in isolation. Full-suite verdicts on this tree require quiescence (`just quiet-check`).
- Not deleted: `_build-ft-fs7` (lease intact for coordinator `just lane-clean`).
