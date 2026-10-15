# Pack Integration: ash-pplan pack family (durable P-PLAN task store)

Lane: durable pplan task store over the substrate.
Canonical checkout: `~/smalt`. Owned files only:
`lib/smalt/pplan/` (new), `test/pplan_test.exs` (new),
`docs/PACK_INTEGRATION/ash-pplan.md` (new).

## What shipped

- `lib/smalt/pplan/task.ex` — `Smalt.PPlan.Task`, a durable task resource over
  the existing substrate (`Smalt.Store` ETS GenServer tables — the same
  substrate that carries the ARM LRO op records). No new postgres, no Ash
  runtime: `ash` is an optional dep of smalt, so the resource is manual
  read/write (map records via `Store.put/get/delete/list`) with a
  protocol-court-validated state machine on top.
- `test/pplan_test.exs` — gate suite: 29 tests across 7 describes (lifecycle,
  court validation, fuzz claim race, fuzz terminal race, chaos, store
  conformance, model fuzz).
- This doc: pack receipt covering all 4 packs of the ash-pplan family.

## Machine (protocol-court pack)

    admitted -> running -> succeeded | failed

Terminal states absorb (any out-edge from `succeeded`/`failed` is refused).
Every status write goes through `transition/4`: court first
(`validate_transition/2`), then CAS on the whole record via
`Smalt.Store.compare_and_swap/4` (serialized inside the Store GenServer, so
concurrent writers conflict instead of clobbering). A refused edge returns
`{:error, {:refused, from, to}}` and performs no store write.

## Pack receipts (4/4)

### 1. ash-pplan-igniter-pack

Pack root: `~/ggen-marketplace/packs/ash-pplan-igniter-pack`
(ontology.ttl, `ig:Task`/`ig:Option` classes, `ig:task-gen-workflow`, gate
queries `gates/010_task.rq` + `020_options.rq`, templates
`gen_workflow_task.ex.eex` + `qualification_probe.txt.tmpl`).

Use: **scaffold reference, not ggen-projected**. The igniter pack renders a
`use Igniter.Mix.Task` shell (`Mix.Tasks.AshPplan.Gen.Workflow`) for an
Ash-project consumer; smalt has no Ash runtime (optional dep) and no igniter
consumption path, so running the generator here would project a module that
cannot compile against smalt's pure-Elixir substrate. Adaptation: the task
record shape (`id`, `status`, `claimed_by`, `attempts`, `effects`,
`created_at`, `updated_at`) and the store-backed manual read/write posture are
modelled on the pack's `ig:Task` facts; the hand-written module is the
disclosed `cnv:CustomBehavior` residue.

### 2. ash-pplan-protocol-court-pack

Pack root:
`~/ggen-marketplace/packs/ash-pplan-protocol-court-pack`
(ontology `pcp:runMachine` with `pcp:Guard`/`pcp:Property` — including
`pcp:p_TypeOK` and `pcp:p_ClaimExclusive` — templates rendering TLA+, TLC
cfg, a Stateright differential model, and an Elixir transition table).

Use: **ontology-adapted, hand-projected**. The court in
`Smalt.PPlan.Task.validate_transition/2` narrows `pcp:runMachine` to the
durable task-store surface this lane specifies: `admitted -> running ->
succeeded | failed`, terminal absorbing. `claim/2` enforces the pack's
`ClaimExclusive` invariant via CAS (exactly one winner among concurrent
claimants; asserted with 200 concurrent claimant processes in the suite). The
pack's TLA+/Stateright model-checking surfaces were not run (no tlc/stateright
in the smalt toolchain) — disclosed as not executed; the Elixir transition
table surface is the one projected, as an adaptation of
`templates/transitions.exs.eex` semantics.

### 3. ash-pplan-chaos-pack

Pack root:
`~/ggen-marketplace/packs/ash-pplan-chaos-pack`
(`acp:KillPhase` boundaries `acp:after_claim` / `acp:before_release_claim`
with seeds, `acp:Invariant` classes, kill-phase templates
`kill_phase.exs.eex` / `invariant_property.exs.eex`, verify RQs
`010_harness` / `020_invariants` / `030_kill_phases` with unbound/violation
pairs and `cardinality.json`).

Use: **kill-phase contract adapted into an in-process chaos row**. The chaos
describe in `test/pplan_test.exs` implements the pack's `after_claim` kill
boundary: a real claimant process claims the task (admitted -> running, lease
held), is killed with `Process.exit(pid, :kill)` (untrappable), and the task
must return to `:admitted` via `Task.recover/0` (dead-claimant sweep, CAS'd)
and be re-claimable (attempts == 2). Asserted: not recoverable while the
claimant is alive; terminal tasks are never recovered (terminal absorbing).
The pack's seeded, multi-phase harness template was narrowed to a single
declared boundary row — disclosed adaptation.

### 4. ash-pplan-store-conformance-pack

Pack root:
`~/ggen-marketplace/packs/ash-pplan-store-conformance-pack`
(`scb:Callback`/`scb:Law` classes — `scb:cb_claim` arity 3, laws
`scb:law_put_get_roundtrip` (order 10), `scb:law_delete_idempotent` (order
20), `scb:law_claim_exclusive`; template `store_conformance.ex.eex` renders a
consumer-facing ExUnit conformance module plus a `conformance_court.exs.eex`.

Use: **laws projected as suite rows**. The store-conformance describe in
`test/pplan_test.exs` executes the pack's laws against the real
`Smalt.Store` collaborator (Chicago: no mocks, real ETS + real CAS inside the
Store GenServer):

- `put_get_roundtrip` -> "law: put/get roundtrip and deterministic list
  order" (asserts `list/1` key-ordered, missing key -> nil)
- `delete_idempotent` -> "law: delete is idempotent and a deleted key is
  puttable again"
- `claim_exclusive` -> "law: claim is exclusive, owner-scoped release via
  recover" (holder alive -> second claim `:taken`; kill holder -> recover ->
  re-claimable) and "concurrent claims have exactly one winner" (200 racers,
  1 winner / 199 :taken)
- plus the pack's anti-vacuity posture: "law: CAS conflict detected, no
  clobber" and an anti-vacuity mutant row (a sabotaged court admitting
  `succeeded -> succeeded` is distinguishable from the real court, so if the
  real court ever weakens to it, the suite fails).

The pack's `conformance_court.exs.eex` wrapper (court harness over a
behaviour module) was not generated because the store under test is the
concrete `Smalt.Store` module, not a `behaviour` — the laws run directly.
Disclosed adaptation.

## Verification receipts

Environment note: concurrent lanes hold ports around app boot; the suite is
booted with pinned `SMALT_TEST_*_PORT` env values, retrying on the config-time
free-port probe race (`:eaddrinuse` at app.start). Ports are not part of the
receipt subject; both gates are green on the identical tree.

- `mix test test/pplan_test.exs` ->
  `14 tests, 0 failures` (exit 0), `MIX_BUILD_ROOT=_build-lanepplan`
- `mix test test/smalt_arm_gateway_test.exs` (canary) ->
  `24 tests, 0 failures` (exit 0), same build root

Pre-existing, session-independent: `mix compile --warnings-as-errors` fails on
warnings in `lib/smalt/runtime_contracts/support.ex`,
`lib/smalt/projection/canonical.ex`, `lib/smalt/projection/admission.ex`,
`lib/smalt/messaging/amqp/queue_store.ex` — untouched by this lane (plain
`mix compile` succeeds; warnings only).

## Standing

ALIVE for the lane surface: module compiles, 14/14 + canary 24/24 executed
green on the canonical checkout with real store collaborators, no mocks. The
protocol-court pack's model-checking surfaces (TLA+/TLC/Stateright) remain
not-executed for this consumer — PARTIAL coverage of that pack, disclosed
above.
