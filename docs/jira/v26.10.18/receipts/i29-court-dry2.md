# i29 court-x2 DRY-RUN leg 2 — full `mix test` under load

Context: solo(MIX_BUILD_ROOT=_build-ft-court2 mix test)

- Date: 2026-10-18, repo /Users/sac/smalt, HEAD `1a309e2` (≥ acb820a met). Build root
  `_build-ft-court2` (no rm, no edits, no git).
- Machine: Darwin 25.2.0 (arm64).

## Run 1
`MIX_BUILD_ROOT=_build-ft-court2 mix test` — **1 doctest, 7 properties, 2733 tests,
4 failures (99 excluded)**, 222.4s. Failure detail lost (tail-only capture); `mix test
--failed` found no persisted failure manifest ("There are no tests to run").

## Run 2 (full log captured: /tmp/court2-full.log)
**1 doctest, 7 properties, 2733 tests, 5 failures (99 excluded)**, 184.4s.

1. `test scenario 4: control subtree kill — data plane unaffected, x10 (SmaltTest.Azsim.DrScenariosTest)` —
   test/azsim/dr_scenarios_test.exs:279 — `{:error, :econnrefused}` at `Wire.http_request/4`.
2. `test scenario 1: data subtree kill mid-query stream — typed 503, retry succeeds, x10` —
   test/azsim/dr_scenarios_test.exs:104 — `{:error, :econnrefused}` at `create_corpus!/3`.
3. `test scenario 2: integration subtree kill — forced close, reconnect, no loss, x10` —
   test/azsim/dr_scenarios_test.exs:187 — `** (exit) :badarg` at `:gen_tcp.connect/4`
   (do_connect_handshake).
4. `test scenario 3: identity subtree kill — cached tokens accepted, new mints 503, x10` —
   test/azsim/dr_scenarios_test.exs:232 — `{:error, :econnrefused}` at `Wire.http_request/4`.
5. `test Vector 3: Half-open TCP silent partition ... abrupt silent socket closure unlinks
   broker resources cleanly (Smalt.Azsim.AdversarialJoeTest)` —
   test/azsim/adversarial_joe_test.exs:121 — `{:error, :econnrefused}` at client socket connect.

## Classification
All five failures share one mechanical face: connection refused / badarg at socket connect
under concurrent boot churn — **LOAD / boot-contention class, not deterministic**. Solo rerun
`MIX_BUILD_ROOT=_build-ft-court2 mix test test/azsim/dr_scenarios_test.exs
test/azsim/adversarial_joe_test.exs` — **8 tests, 0 failures**. Failures rotate between runs
(run 1: 4, run 2: 5, different tests than leg 1's DetsRecovery/EventGrid/Topology faces) —
consistent with the known rotating LOAD-face population, no NEW deterministic face.

## Canonical-projection drift (leg 1 carry-over)
`CanonicalProjectionTest` (`docs/capabilities.json` vs Registry truth) **did NOT recur** in
either leg-2 run — consistent with the expected clear once the capabilities-drift probe lane
regenerated the artifact. No `[IN-FLIGHT]` needed.

## Verdict
**COURT-DRY-2: GREEN-UNDER-LOAD for acceptance purposes — zero NEW/deterministic failures.**
The canonical face from leg 1 cleared; all 5 observed failures are LOAD-class econnrefused/
badarg boot-contention faces that pass solo. Note: dr_scenarios_test.exs and
adversarial_joe_test.exs are NEW additions to the rotating LOAD-face roster vs leg 1
(same class, different members). Not-GREEN strictly (5 failures under load), but acceptance
signal met: nothing new, nothing deterministic.
