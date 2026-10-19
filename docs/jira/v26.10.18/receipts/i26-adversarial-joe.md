# i26 — adversarial_joe Vectors 1 & 3 (AZB-10 flagged, pre-existing)

Date: 2026-10-18 · Lane: `_build-ft-jo` (private build root) · Standing: **ALIVE**

## Subject

`test/azsim/adversarial_joe_test.exs` Vectors 1 and 3, flagged by AZB-10
(`docs/jira/v26.10.18/receipts/azb-10-cross-plane.md` caveat) as pre-existing
failures (failed with the azsim test file removed from the run and on shared
baseline `_build`).

## Diagnosis

**Solo reproduction failed — the tree moved.** Fresh `_build-ft-jo` full
compile of the current tree: `4 tests, 0 failures` on the first clean solo
run (background log, exit 0). The AZB-10 observation window had
`lib/smalt/messaging/amqp/connection.ex` mid-edit by another lane (in-flight
AZB-05/06/09 batch, landed at 9f4c19d) — the exact "in-flight batch surface,
owner-lane, not a soak defect" classification v2-soak already assigned
(`docs/jira/v26.10.18/receipts/v2-soak.md`).

**But Vector 3 carried a real stale premise, reproduced verbatim.** The test
hard-coded port `5672` (the substrate's fixed port) while the test app boots
its AMQP listener on a probed-free ephemeral port
(`config/test.exs` `amqp_port`; `Smalt.Config.amqp_port/0`). It passed solo
only because a substrate beam (pid 40499) happened to hold 5672 — an
environment-dependent pass, not a hermetic one. Shim run (5672→5999, i.e.
substrate-down condition):

```
1) test Vector 3: ... (Smalt.Azsim.AdversarialJoeTest)
   test/azsim/adversarial_joe_test.exs:121
   ** (MatchError) no match of right hand side value:
       {:error, :econnrefused}
1 test, 1 failure (3 excluded)
```

**Vector 1: clean, no change.** 10/10 solo runs green on the settled tree
(`4 tests, 0 failures` × 10). Its wire-tier failures were the in-flight
connection.ex batch (v2-soak leg 2 witness); the batch has landed. No defect
in the vector's mechanics: `Store.put/3` writes directly to a public
`write_concurrency` ETS table, so the flood never enters the Store mailbox;
mailbox-drain and memory asserts are structurally satisfied.

## Fix (Vector 3, stale-premise class — test-side)

```
+      amqp_port = Smalt.Config.amqp_port()
       {:ok, client_sock} =
-        :gen_tcp.connect({127, 0, 0, 1}, 5672, [:binary, packet: :raw, active: false], 2000)
+        :gen_tcp.connect({127, 0, 0, 1}, amqp_port, [:binary, packet: :raw, active: false], 2000)
```

Same substitution at the health-probe `:gen_tcp.connect` inside the
`eventually/2` body. Behavior source: `lib/smalt/registry.ex:188` /
`lib/smalt/config.ex:537` (`Application.get_env(:smalt, :amqp_port, 5672)`),
boots at `lib/smalt/messaging/amqp_broker.ex:36`. Not product — no lib change.

## Non-vacuity of the fix

Shim (`amqp_port() + 99999`, marked run, file restored after):

```
1 test, 1 failure (3 excluded)
```

A court that cannot flip is FAIL; the fixed test still fails loudly when the
configured listener is absent.

## Verification (verbatim)

- Clean-slate solo (pre-fix): `4 tests, 0 failures` (exit 0)
- Stability sweep, 10 solo runs: `4 tests, 0 failures` × 10/10
- Post-fix final solo: `4 tests, 0 failures`, exit 0
- Anti-vacuity shim (dead port): `1 test, 1 failure` — loud, as required
- Compile warning (pre-existing, out-of-lane): `Smalt.WasmEngine.seal/2 is
  undefined` at line 176 (Vector 4 catches it typed; noted, not this lane's)

## Standing

ALIVE — Red→Green witnessed for Vector 3 (red via substrate-down shim; the
ambient environment currently masks the red because substrate holds 5672).
Vector 1 classified clean with 10/10 evidence. No git actions taken; diff
left in worktree (1 file, +8/-2... measured +6/-2 lines).
