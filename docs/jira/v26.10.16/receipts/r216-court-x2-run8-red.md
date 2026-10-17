# Court-x2 wrap runs 8–9 — RED

- Standing: **RED — gate FAIL, no two-green** (terminal verdict from run 9, the newest completed invocation)
- Lane: FINISH court tail (lane 1), 2026-10-16
- Subjects: `tmp/court-x2-wrap-run8.log`, `tmp/court-x2-wrap-run9.log` (both `COURT_X2_RC=1`)
- No fixes applied (per lane contract: typed defect list only)

## Run 8 (17:52–18:31) — RED, environmental (port-contention)

Both ex-unit runs printed `0 failures — GREEN` with empty failure-set diff;
the gate failed only on the **SDK smoke tier, port-contention class**:

- Run 1: exit **137** (SIGKILL) — `test/sdk-smoke/{amqp,blob,cosmos}.test.cjs`
  each `test failed` (~70 ms each, connection-refusal shape), then
  `recipe 'test-sdk-smoke' was terminated on line 96 by signal 9`.
- Run 2: exit **3** — loud fail-closed refusal:
  `[sdk-smoke] port 9445 is occupied. Do NOT kill the holder (it may be another lane's live substrate).`
- Holder: PID 86578 `beam.smp` LISTENing on `127.0.0.1:9445`, launched 17:56
  with `arm_port=9445` (independent substrate, not court-run1's boot). Left
  running per the port law. Class: **port-contention (known set)**.

## Run 9 (18:28–18:47) — RED, shifting-failure signature

`1 doctest, 7 properties, 2428 tests` — run 1: **2 failures**; run 2:
**1 failure**. Summary lines NOT GREEN both runs; failure-set diff non-empty
(shifting-failure alarm fired).

### Typed defect list

1. **Class: Enclave.Lifecycle ordering (known set)** — run 1 only, absent run 2:
   - `test/enclave_lifecycle_test.exs:28` —
     `test composite baseline fixture lifecycle: green end to end, in-process (Smalt.Enclave.LifecycleTest)`
     verbatim assertion site: `assert {:ok, report} = Lifecycle.run(@fixture, state_path: state_path)`
   - `test/enclave_lifecycle_test.exs:75` —
     `test OCEL stage emission is fail-safe and registry-gated, never lifecycle-failing (Smalt.Enclave.LifecycleTest)`
     (assertion inside the registry-gated branch; fails as part of the same
     lifecycle run ordering shift)
   - Did not reproduce in run 2 of the same gate — flake/ordering signature,
     not a deterministic regression.

2. **Class: NEW — atom-flood fuzz regression (not in known set)** — run 2 only:
   - `test/amqp/fuzz_test.exs:550` —
     `test 5000 unique long symbol source/target keys mint no new atoms (Smalt.Amqp.FuzzTest)`
     (tag `:atom_flood`). Asserts no new atoms are minted decoding a hostile
     attach whose source is a raw AMQP map of 5000 unique wire-sourced keys —
     regression test for the retired `String.to_atom/1` fallback in
     `safe_atom/1`. **Not** seal-suite post-hardening, **not**
     `semantic_projection:545 FLAKE_SOLO` (absent from both runs), **not**
     port-contention this run.

3. **Class vs run 7** (prior invocation, for continuity): run 7 was
   SealTest x4 (`test/affidavit_seal_test.exs:54,82,94,126`,
   seal-suite post-hardening class, candidate: in-flight wasm_engine
   churn-hardening lane) + `semantic_projection_test.exs:545`
   (`test non-binary field values project nil, well-formed neighbors untouched (Smalt.Semantic.StoreRead.Lens7FieldPolicyTest)`,
   FLAKE_SOLO known class) in run 2. **Neither reproduced in run 9** — the
   SealTest signal did not recur once the churn lane's compile noise settled,
   and 545 did not fire.

## Verdict

RED, terminal for this poll window. Two distinct signatures across runs 8/9
and a NEW flake class (`:atom_flood`, `test/amqp/fuzz_test.exs:550`) that
fired once and did not recur within the gate. Rerun court-x2 once the tree is
quiet (holder on 9445 gone, churn lane landed) before any two-green receipt;
if `:atom_flood` reproduces, it graduates from flake-candidate to defect.
