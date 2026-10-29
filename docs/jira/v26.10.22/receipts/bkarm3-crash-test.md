Standing: ALIVE (3/3 live crash legs witnessed on the kind BEAM swarm; kc court legs coded+compiled, green run blocked by fleet load — see Blockers) · Context: solo

# BK-ARM3 — crash-test receipt (Armstrong lane 3: test by crashing)

## What was done

Live crash testing of the kind BEAM swarm (BK-SWARM's 2-replica StatefulSet on
the kind cluster, 1 node at witness time), plus 3 kind-typed crash legs
(`(kc1)`, `(kc2)`, `(kc3)`) added to `test/integration/swarm_court_test.exs`.

## Live crash timelines (real, 2026-10-22 ~09:42–09:47 PDT)

Traffic = `Smalt.Store.put` round-trips via the release `smalt rpc` face at
~300–400 ms cadence, each stamped. All ms stamped from the kill. Timelines
preserved at `/tmp/bkarm3/*.timeline` (raw).

### Leg 1 — kill pod 0 mid-traffic (witnessed live)

```
+0       KILL smalt-swarm-0        (kubectl delete pod --wait=false)
+224     pod object gone
+3316    pod Running again (kubelet recreated)
+5521    rpc-alive  (smalt rpc node())
+6073    mesh-rejoin: :pong to survivor over the headless-DNS node name
+6558    serving-put :ok
+7059    serving-get {:ok, %{healed: true}}
```

Traffic: last ok −563 ms before kill, first ok +4775 ms after → measured
outage ≈ 5.3 s (6 ok / 7 fail events; fails span the terminating window).

### Leg 2 — kill pod 1 while pod 0 serves (witnessed live)

```
+0       KILL smalt-swarm-1
+206     pod object gone
+2772    pod Running again
+5269    rpc-alive
+5856    mesh-rejoin :pong
+6405    serving-put :ok
+6959    serving-get :ok
```

**Pod 0 traffic: 12 ok / 0 fail — zero traffic loss through pod 1's death
(first ok +127 ms after the kill: not even one cadence window lost).**
Full survivor-isolation witnessed: kubelet's heal of pod 1 is invisible to
pod 0's clients.

### Leg 3 — kill BOTH pods (witnessed live)

```
+736    BASELINE both pods serving
+836    KILL both deleted
+4584   pod-0 Running
+5349   pod-1 Running
+6963   pod-0 rpc-alive
+8302   pod-0 mesh-rejoin 0→1 :pong
+9443   pod-0 serving-put :ok
+9848   pod-1 serving-put :ok
+9892   DONE full recovery from empty
```

Full recovery from empty in 9.9 s wall: StatefulSet recreates in ordinal
order, mesh re-forms over headless DNS, both pods serving within 10 s.

## Post-crash state semantics (typed)

`bkarm3-crash0-r` / `bkarm3-kc2-pre` keys read `:error` after pod recreation —
fresh per-pod ETS. The swarm heals availability but NOT state: per-pod
partitioned, in-memory, no replication. Court leg kc2 asserts the negative
(a key surviving pod recreation = persistence appeared = re-type the
contract); the crash-leg helper re-checks the cross-pod partition post-heal
whenever survivor ≠ victim.

## Court additions (test/integration/swarm_court_test.exs)

- `(kc1)` kill pod 1 while pod 0 serves: asserts 0 traffic fails on pod 0
  through the kill + full 6-phase recovery timeline (pod-object-gone →
  pod-running → rpc-alive → mesh-rejoin → serving-put → serving-get).
- `(kc2)` kill the serving pod: asserts ≥1 traffic fail (the kill MUST be
  witnessed as an outage — a kill that breaks no traffic is a fake crash) +
  full heal + fresh ETS post-crash (`:error` on the pre-crash key).
- `(kc3)` kill both pods: both Running → mesh both directions :pong → both
  serving; 240 s bounded-poll deadlines; every wait a bounded poll on a real
  observable, no sleeps as coordination (only the audited poll step + traffic
  cadence).
- Loud typed skip: kind absent → `{:skip, :no_kind_cluster}`; <2 Running
  smalt-swarm pods → `{:skip, :swarm_not_deployed}` — never a fake pass.
- Disclosed hardening: `@poll_timeout` 15s → 60s (peer-boot poll expired
  under fleet load; load ~51, 34 beams live — `:peer.start` needs >15 s to
  converge when saturated).

## Blockers (typed)

- **Fleet-load peer-boot**: with the BK fleet saturated (load 51, 34 beams),
  `:peer.start_it/2` exits with the stdlib hidden timeout in setup_all → all
  8 tests invalid. Not a crash-leg defect: run 1 passed setup_all + all 4
  host-side legs + kind leg (k) with identical code paths; the kc legs ran
  real kubectl deletes and real crash timelines in that run (their failures
  were the 60 s ExUnit default timeout — since fixed with `@tag timeout:
  300_000` — and concurrent interference below).
- **Concurrent cluster mutation**: mid-kc1, another lane redeployed the
  swarm StatefulSet (both pods recreated mid-leg → carry-pod ETS vanished →
  traffic fails). The kind cluster was also recreated wholesale (cluster
  renamed `kind-smalt`, 3 nodes; `~/.kube/config` clobbered, kind-smalt
  context dropped; restored via `kind export kubeconfig --name kind-smalt`).
  A quiet-window rerun (`/tmp/bkarm3/wait_and_run.sh`, load-gated) is armed
  to convert this to a fully green in-suite witness.
- test-budget: 3 new tests (`kc1/kc2/kc3`) will register unbudgeted at next
  seed.

## Disclosed cross-lane unblock fixes (compile-freeze SLA)

1. `lib/smalt/cluster.ex` — removed stray `schedule_next(cfg.poll_ms)`
   (arity-1, undefined; duplicated the Task's `schedule_next(parent,
   cfg.poll_ms)` at the run_poll call site). Compile was broken tree-wide.
2. `test/integration/swarm_court_test.exs` — `Poll.eventually` had no
   alias-resolvable module (`Poll` undefined); resolved to the one audited
   `SmaltTest.Internal.Poll`.
3. `lib/smalt/powl2/executor.ex` + `lib/smalt/messaging/kafka/conn.ex` —
   NOT touched (actively mid-edit by their lanes; waited out both via
   bounded poll; both healed by their owners).

## Commands (real, embedded)

```
$ MIX_BUILD_ROOT=_build-bkarm3 elixir --name bkarm3-court@127.0.0.1 \
  --cookie smalt_swarm_court -S mix test test/integration/swarm_court_test.exs --seed 0
# run 1 (quiet window): host legs (a)-(d) passed, kind leg (k) passed,
#   kc legs: ExUnit 60s timeout + concurrent-redeploy interference
# runs 2-6 (saturated): setup_all :peer.start_it exit time out (load 51)
$ MIX_BUILD_ROOT=_build-bkarm3 elixir --name bk3@127.0.0.1 -S mix test \
  test/integration/swarm_court_test.exs --dry-run
Result: 0 tests    # 8 tests listed, compiles clean
```
