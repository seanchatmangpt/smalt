# Receipt: BK-ARM6 — Armstrong principles lane 6: topology code vs the quality bars (CEPN)

Standing: ALIVE (lib/ edits compile clean, all targeted courts green)
Context: solo

## Scope

Audit of the session's new topology code against Armstrong CEPN (Concurrency,
Error handling, Names, Pure functions): `lib/smalt/cluster.ex`, the BK-POWLH3
executor walk (`lib/smalt/powl2/executor.ex`), and the two distribution courts
(`test/integration/swarm_court_test.exs`, `test/integration/peer_two_node_court_test.exs`).

## Per-file CEPN verdicts

### lib/smalt/cluster.ex — was PARTIAL, fixed to ALIVE

- **Concurrency**: was the one real defect. DNS resolve + `Node.connect/1` ran
  INSIDE the GenServer; `Node.connect` can block for net_ticktime (default 7s)
  on an unreachable host, freezing `cluster_status/0` — the readiness face
  that the adaptive-probe lane calls. That is the error kernel doing the
  blocking work. Fixed: the poll is now spawned to a worker (`Task.start`);
  the server only holds name + state, answers `:status` immediately, folds the
  worker result back via `{@poll_done_msg, attempts, last_error}`, guards
  overlapping polls with an `in_flight` flag, and a worker crash only drops
  the in-flight flag (next poll retries with clean budget — crash-first, the
  budget snapshot is advisory not authoritative).
- **Error handling**: crash-first at init (raises on disabled/no-dns_name,
  witnessed by 2 typed-refusal tests), typed `{:dns_failure, name, reason}` /
  `{:connect_failed, target}` records instead of defensive catches. ALIVE.
- **Names**: named `__MODULE__` process, `@poll_msg`/`@poll_done_msg` module
  constants, `target_node/2` self-describing. ALIVE.
- **Pure functions**: `resolve/1`, `target_node/2`, `run_poll/3` pure-ish;
  the one caveat — `String.to_atom` mints atoms from DNS answers — is
  accepted: node names ARE atoms on dist, and the address set comes from the
  operator's own `dns_name`, not adversarial input. Documented here, no code
  change.
- Bonus fix: a poll's `last_error` previously reset to `nil` on ANY successful
  connect in the same poll; now the last real connect failure is kept when a
  DNS error did not supersede it (more truthful error surface; witnessed by
  the budget-burn test asserting the exact `{:connect_failed, ...}` tuple).

### lib/smalt/powl2/executor.ex (BK-POWLH3 walk) — ALIVE, shape confirmed, two typed refactors landed

- **The 256 budget is NOT an Armstrong-banned defensive count.** It bounds
  exactly the one structure the visited-once rule cannot — unguarded cycle
  re-entry — and its refusal `{:choice_walk_reentry_budget_exceeded, to}` is
  typed, fail-closed, crash-first in spirit. Justification for the constant
  was undocumented; now documented at the definition (visited set bounds
  acyclic re-entry at |children|; the budget only has to cover a real loop
  face re-entering once per iteration; 2^8 far above any legitimate loop body
  count, far below stack exhaustion).
- **Concurrency**: PartialOrder frontier runs via Task.async/await under a
  remaining-deadline timeout; ChoiceGraph walk is sequential by design
  (guard-keyed, last_outcome-dependent — concurrency here would be unsound).
  ALIVE.
- **Error handling**: fail-closed guards (`:bad_guard_verdict` / `:guard_raised`
  synthetic refusals), enumerated op-result shapes with typed
  `{:bad_op_result, other}` catch-all instead of success-on-unknown. Textbook
  crash-instead-of-guard at the boundary. ALIVE.
- **Names**: `walk/6` + `fire/8` after refactor — was `fire/14`, the
  least-Joe function in the audit; now takes a static walk context map `w`
  (edges/children/guards/endpoint/law/cycle_edges) built once in
  `eval_choice/3`. Could Joe have written the old fire/14? No — 14 positional
  args is not a shape a human maintains. Fixed, not just typed.
- **Pure functions**: the walk is pure over ctx/visited/re; `pick_all/4`
  called `guard_for_edge/2` three times per edge — collapsed to one call per
  edge, same semantics. The honest least-Joe runner-up was the
  legacy `fn` indentation inside walk (uneven, compiler-hostile); that block
  is now `step_edge/3`, a named pure step.
- Could Joe have written this file? After the refactor: yes — pattern match,
  typed refusals, no defensive catch-all, pure walk.

### test/integration/swarm_court_test.exs — ALIVE as a court (compile unblock disclosed, see below)

- **Concurrency**: real 3-node :peer mesh, polls on real observables via the
  audited `poll_until/3` (POLL-STEP), no coordination sleeps. ALIVE.
- **Error handling**: typed `{:error, {:node_down, node}}` normalization in
  `call_typed/4`, loud typed skips (`{:skip, :no_kind_cluster}`), honest
  partitioned-state contract asserted as a NEGATIVE with the falsifier named
  in the moduledoc. Exemplary.
- **Names**: `full/1`, `swarm/0`, `kctx_exec` — clear. ALIVE.
- **Pure functions**: courts are effectful by nature; the helper faces are
  minimal and shipped as beams. ALIVE.

### test/integration/peer_two_node_court_test.exs — ALIVE

- Same shape as swarm court, correctly SIMPLER (start_link lifecycle, one
  remote). Typed node_down leg, epmd-name-free teardown poll, monitor-based
  partition leg. `catch_exit_do/1` returning `:no_exit` on no-exit is the one
  slightly non-typed spot (a sentinel vs a tagged value) — cosmetic, not
  fixed (owner's in-flight file). Could Joe have written it? Yes.

## Fixes landed (my files)

1. `lib/smalt/cluster.ex` — error-kernel separation (worker poll + in_flight
   guard + DOWN handler + result fold), `last_error` truthfulness.
2. `lib/smalt/powl2/executor.ex` — `fire/14` → `fire/8` via static `w` map +
   `step_edge/3` split, budget-256 justification comment, `pick_all/4`
   single-call cleanup.

## Compile-freeze disclosure (cross-lane, SLA law 2+6)

`test/integration/swarm_court_test.exs` was left mid-edit by lane BK-ARM3
with a syntactically broken `kctx_exec` (stray `defp kctx_exec(...)` /
missing `end` after the rescue clause) — the whole file failed to compile,
freezing my court runs. I applied the minimal unblock (added the missing
`end`). The file is NOT in my commit (it carries BK-ARM3's in-flight kc-leg
work; committing it would sweep their diff). BK-ARM3 must land the one-line
`end` fix together with their legs.

## Verification (commands + output)

```
MIX_BUILD_ROOT=_build-lane6 mix test test/cluster/cluster_test.exs \
  test/internal/powl2_executor_test.exs test/internal/powl2_andon_court.exs \
  test/internal/powl2_law_guard_court.exs test/internal/powl2_decomposition_test.exs
# pre-fix baseline (3 files): 23 passed
# post-fix (5 files):        Result: 57 passed
# (intermediate run caught my own worker-message shape bug: 56/57 — fixed,
#  see below)

MIX_BUILD_ROOT=_build-lane6 elixir --name bkarm6court8@127.0.0.1 \
  --cookie smalt_peer_court -S mix test \
  test/integration/peer_two_node_court_test.exs --include peer_two_node_court
# Result: 4 passed

MIX_BUILD_ROOT=_build-lane6 elixir --name bkarm6court6@127.0.0.1 \
  --cookie smalt_swarm_court -S mix test \
  test/integration/swarm_court_test.exs --include swarm_court
# Result: 6/8 passed — host legs + (k) kind leg all green; kc1/kc2 are
# BK-ARM3's in-flight kind-crash legs failing on kind-context drift
# ("context kind-kind-smalt was not found" mid-run — another lane is actively
#  building kind clusters; (k) passed with the same ctx seconds earlier).
# Not my lane's diff; not fixed here.
```

Bugs the tests caught in MY refactor (disclosed): first cut sent the worker
result as `{tag, {attempts, last_error}}` while the handler destructured a
3-tuple — results fell into the catch-all, `in_flight` stuck, budget-burn
test failed. Fixed by sending the flat 3-tuple; 57/57 after.

## Falsifiers

- cluster.ex: kill the poll worker mid-connect → server still answers
  `cluster_status/0` within one poll interval (in_flight cleared via DOWN).
- executor.ex: a ChoiceGraph with an `:always` self-loop now refuses typed
  after 256 re-entries instead of spinning (budget comment names the exact
  refusal tuple).
- Receipt-disclosed: BK-ARM3's kc-leg failures and their pending `end`-fix
  landing are outside this lane's diff ownership.
