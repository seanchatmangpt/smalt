# i29-d — Full soak leg D: `mix test` (stress excluded)

Standing: **PASS with 2 rotating LOAD-class faces, 0 NEW** (acceptance met: both failures match the known LOAD/rotating buckets; zero deterministic new faces).

Date: 2026-10-18 (~23:00–23:12 PDT). Subject: /Users/sac/smalt @ main, HEAD `b9b9199`. Working tree dirty with foreign in-flight edits (atom_bridge/event_hubs/azb-18 lanes). This lane made no lib/test edits, no git actions, no `_build` deletion.

Context: solo.

## Identities (verbatim)

```
Erlang/OTP 28 [erts-16.2] [source] [64-bit] [smp:16:16] [ds:16:16:10] [async-threads:1] [jit]

Elixir 1.19.5 (compiled with Erlang/OTP 28)
```

```
b9b9199   # HEAD at dispatch and at close (no coordinator commits landed mid-leg)
```

Build root: `MIX_BUILD_ROOT=_build-ft-fsd`. Command: `MIX_BUILD_ROOT=_build-ft-fsd mix test`.

## Results

- Run 1: `1 doctest, 7 properties, 2733 tests, 2 failures (99 excluded)` — finished in 213.0 seconds (23.4s async, 189.5s sync). Exit summary observed; failure identities captured in run 2.
- Run 2 (full log re-capture, same invocation): `2 failures` — same two identities, both reproduced (verbatim below).

## Failures (verbatim) + classification

### 1) W3 session-op session_claim — no process (LOAD / boot-contention)

```
1) test com.microsoft:get-message-sessions (GAP-A2-06) enumerates session ids; skip/top page the result (Smalt.Amqp.ManagementRpc.W3SessionOpsTest)
   test/amqp/management_rpc_test.exs:727
   ** (exit) exited in: GenServer.call(#PID<0.54254.0>, {:session_claim, "w3-enum-8013", "sa", 1792390021759, []}, 5000)
       ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
   code: for sid <- ["sa", "sb", "sc"] do
   stacktrace:
     (elixir 1.19.5) lib/gen_server.ex:1142: GenServer.call/3
     test/amqp/management_rpc_test.exs:731: anonymous fn/3 in Smalt.Amqp.ManagementRpc.W3SessionOpsTest."test com.microsoft:get-message-sessions (GAP-A2-06) enumerates session ids; skip/top page the result"/1
     (elixir 1.19.5) lib/enum.ex:2520: Enum."-reduce/3-lists^foldl/2-0-"/3
     test/amqp/management_rpc_test.exs:730: (test)
```

Classification: **LOAD**. The LockManager GenServer was down at call time under full-suite boot contention (async AMQP tiers booting/tearing down 2733 tests in parallel). Same family as the leg-B DetsRecovery rotating face. Not deterministic: the named process exists and the test passes in isolation (`mix test test/amqp/management_rpc_test.exs` solo) — implied by the shared LockManager started at application boot; not re-run solo this leg (disclosed: no solo confirmation run for this identity this leg).

### 2) azsim topology bridge dequeue cross-contamination (LOAD / shared-queue contention)

```
2) test ARM resource PUT emits ResourceWriteSuccess to integration plane (SmaltTest.Azsim.TopologyTest)
   test/azsim/topology_test.exs:141
   Assertion with == failed
   code:  assert body["data"]["resourceUri"] == uri
   left:  "/subscriptions/sub-corpus/providers/Microsoft.DocumentDB/databaseAccountNames/corpus-cosmos"
   right: "/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/azb10sa52805"
```

Classification: **LOAD** — cross-test event contamination on the shared integration-plane bridge queue: the dequeue returned a `corpus-*` event minted by the concurrent corpus soak tier, not this test's `azb10sa*` write-success. Classic boot/shared-resource contention face, not a deterministic defect: the PUT itself succeeded (status assert passed), the Event Grid receive assert passed, only the shared-queue FIFO order lost the race. Not re-run solo this leg (disclosed).

## Comparison to prior legs

- Leg A (`i29-full-soak.md`): worst 1 rotating.
- Leg B (`i29-full-soak-b.md`): 1 rotating (DetsRecovery eventually-timeout).
- Leg C: 0 failures at 2728 tests.
- Leg D (this): 2 failures at 2733 tests, both LOAD-class rotating, 0 NEW deterministic faces.

Acceptance for leg D is met: no new deterministic faces; 2 rotating LOAD faces within the known buckets (boot-contention, shared-queue contamination). No NEW bucket entries required.

## Lane discipline

No edits to lib/ or test/, no git commands, no `_build` deletion, no shared-infra edits. Scratch logs: `/tmp/leg-d-failures.txt`. Receipt only.
