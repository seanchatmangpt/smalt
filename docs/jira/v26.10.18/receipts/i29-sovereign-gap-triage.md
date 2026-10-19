# i29 — Sovereign Midnight :sovereign_gap triage (1.3 / 2.2 / 2.3 / 3.1 / 3.2 / 5.3)

Standing: PASS-with-caveat — 5/6 pass deterministically; 3.1 flaked 1 in 4 full-tag runs.
Subject: /Users/sac/smalt @ main 0009df3 (working tree, no lib/ or test/ edits made).

Command (per test, isolated):

    cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ft-sg mix test \
      test/azsim/sovereign_midnight/sovereign_midnight_test.exs --include sovereign_gap \
      --only test:"<name>"

Note: excon silently ignored the `--only test:` filter; each invocation ran all 6 tagged
tests (`6 tests, 0 failures (12 excluded)` — 12 = the untagged tests in the file). The
named-filter runs are therefore equivalent to the full-tag run. Verbatim per-test runs:

    1.3 Key Vault Crypto        → 6 tests, 0 failures (12 excluded)
    2.2 ARM Optimistic (ETag)   → 6 tests, 0 failures (12 excluded)
    2.3 Microsoft.Authorization → 6 tests at 22:05:33, 0 failures (12 excluded)
    3.1 Service Bus             → 6 tests, 0 failures (12 excluded)
    3.2 Event Hubs              → 6 tests, 0 failures (12 isolated) 0 failures
    3.2 / 5.3                   → 6 tests, 0 failures (12 excluded)

Full-tag suite run (all 6 together, 18 tests total in file):

    run 1 (22:04): 18 tests, 1 failure      ← the only observed failure
    run 2:         18 tests, 0 failures
    run 3:         18 tests, 0 failures
    run 4:         18 tests, 0 failures

## The single observed failure — verbatim

Run 1 (22:04), test 3.1, line 332:

    1) test Phase 3: The High-Frequency Wire Storm 3.1 Service Bus: Lock Expiry
       Rejection (:lock_lost / 410 parity) (Smalt.Azsim.SovereignMidnightTest)
       test/azsim/sovereign_midnight/sovereign_midnight_test.exs:308
       match (=) failed
       code:  assert {:error, :lock_lost} = QueueStore.complete(queue, seq, lock_token: token1)
       left:  {:error, :lock_lost}
       right: :ok

    Finished in 1.4 seconds (0.00s async, 1.4s sync)
    18 tests, 1 failure

## Classification and G-register mapping

| Test | Verdict | Class | G | v26.10.19 work order |
|---|---|---|---|---|
|---|---|---|---|---|
| 1.3 KeyVault crypto + bit-flip | PASS (deterministic, 4/4 runs) | (c) existing capability — `KeyVaultActions.wrap_key/unwrap_key` RSA-OAEP-256 round-trip and 1-bit-corruption `{:error, 400/404, map}` refusal all exist | G5 (injector) |
| 2.2 ARM NSG ETag race | PASS | (c) existing capability — NSG PUT 201 + `etag` header + If-Match CAS; 16-way race settles winners+losers=16 | G6/COVERED per register |
| 2.3 Policy 403 | PASS | (c) existing capability — `Policy.put_policy_definition/put_policy_assignment` deny effect → storage-account PUT 400 with `PolicyViolation`/`RequestDisallowedByPolicy` | G5 (cancel-race injector only) |
| OPEN→CLOSED line: 3.1 SB lock-lost | FLAKE 1/4 | (b) test/coordination premise, NOT a product gap — the typed face exists (`QueueStore.complete` token-scoped compare-and-settle, `{:error, :lock_lost}` documented in queue_store.ex:334-352) | G5 (lock-lost 410 typed face — already closed by queue_store.ex token-scoped settle) |
| 3.2 EH checkpointing | PASS | (c) existing capability — `EventHubs.send_event/receive_events/checkpoint` on fixed partitions ["0","1"] | G5/G6 (mid-stream detach/resume injector still MISSING) |
| 5.3 ARG KQL | PASS | (c) reachable via different API — `ResourceGraph.query/3` works; the registered gap is that the HTTP route family is absent (AZB-20 gap-6) | G6 (ResourceGraph routes) |

## Findings

2. **Premise stale**: the dispatch premise "6 :sovereign_gap failures" predates commit
   0009df3 ("typed :sovereign_gap exclusions for G1–G6"); the current tree passes 5/6
   deterministically and 3.1 is a 1-in-4 flake, not a stable red.
3. **3.1 flake mechanism (suspected)**: the test injects `now_ms` into
   `dequeue_matching` but `complete/3` compares against the message row's currently
   stored token via the singleton `QueueStore` GenServer; run 1's `right: :ok` on the
   stale-token settle means the row's stored token was still token1 — consistent with
   the 1600ms reclaim in `dequeue_matching(now_ms: 1600)` not persisting the new token
   to the row (reclaim-vs-store token swap racing the serialized `complete`). One
   observation; needs a repro harness before filing a defect. Needs ownership in
   queue_store.ex (another lane owns that file per in-file disclosure note).
3. **5.3 is the only real residual product gap in the six**: module-level
   `ResourceGraph.query/3` works, but no HTTP route family (per SOVEREIGN_MIDNIGHT.md
   AZB-20 gap-6), so real SDK/HTTP clients have no surface. That is the G6 work.
4. 1.3 / 2.2 / 2.3 / 3.2 already exercise live capabilities; their G-rows
   (G5/G6) should be narrowed to the remaining injector/route work only, not re-opened
   as product gaps.

## v26.10.19 work-order sketch (per gap)

- **G5-narrow** (1.3, 2.3, 3.1, 3.2): only the injectors remain —
  - 3.1: determinize `QueueStore.complete` token swap under reclaim (root-cause the
    singleton GenServer ordering; add a regression test asserting the stale-token
    settle refuses when the reclaim raced) — owner: messaging lane, queue_store.ex.
  - 3.2: mid-stream detach/resume injector for EH checkpoint resume.
  - 1.3: JWT expiry-race injector (register Phase-1 row: "expiry race … MISSING").
  - 2.3: policy cancel-race injector.
- **G6** (5.3): stand up the ResourceGraph HTTP route family so
  `POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01` serves
  `ResourceGraph.query/3`; receipt-gate the flip of the AZB-20 gap-6 row.
- **G1/G2/G3/G4**: untouched by these six tests — unchanged standing (Queue Storage
  surface, X-ARR-ClientCert, DLQ spillover, split-brain plane).

Context: solo. Machine report: n/a (no bench lane; no ports held).
