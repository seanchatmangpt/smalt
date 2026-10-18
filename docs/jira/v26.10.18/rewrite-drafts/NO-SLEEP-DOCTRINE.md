# No-Sleep Doctrine

Status: DRAFT (global rule candidate; frozen tree — no code edits, no git).
Window: v26.10.18. Companion drafts:
`assert-eventually.ex.md`, `fence10-ratio.md`, `budget-gate.md`.

## Statement

**Process.sleep is not an acceptable test or production methodology.**

A sleep coordinates nothing: it guesses that time will substitute for an
observation, and the guess is wrong exactly when the system is under the
load that matters. In tests it buys flake-or-slowness — either the sleep is
too short and the test goes red under parallel load, or it is padded until
it is slow on every green run to avoid the flake. In production it buys
races — the slept-for condition arrives early, late, or never, and the
caller proceeds into a state that does not exist. Time is not a proxy for
state. The correction in every case is the same: observe, don't wait-and-hope.

Three laws follow, one per surface, plus an enforcement mechanism. The
framing is Armstrong/Valim/Daniel: **let it crash — supervision owns
retries** (a supervisor restarting a child is a retry loop with backoff
that the runtime already implements; a hand-rolled `Process.sleep` retry
loop inside a start function re-implements supervision badly);
**explicit state machines own readiness** (readiness is a state —
`:starting → :ready` — transitions fire on events, not on clock expiry);
**the runtime owns time** (the only legitimate sleep is the runtime
scheduling the process away until a real-world interval elapses).

## Law 1 — Test side: fixed sleeps banned; poll observables

In `test/`, `Process.sleep(N)` as a coordination step ("give it 200ms, it
will definitely be done") is banned. The lawful forms:

1. **Bounded polls on observables** — `SmaltTest.AssertEventually.eventually/2`
   (draft: `assert-eventually.ex.md`) polls a real observable (Store row,
   ETS table, HTTP status) on a monotonic deadline with typed immediate-fail
   on an unexpected shape. It collapses the four proven in-repo instances:
   i21 `sweep_until_terminal/3` (`test/lro_test.exs:1181`), i22
   `poll_until_succeeded/2` (`test/arm_error_corpus_test.exs:493`), the i22
   `resilient_clear` family (`test/corpus/helper.exs:38`,
   `test/compliance/c1_arm.exs:807`, `c3_cosmos.exs:1038`,
   `c4_blob.exs:1506`). Fixed sleeps and deadline-bounded polls differ in
   kind, not degree: a fixed sleep asserts the world converged *before* the
   check; a bounded poll asserts it converges *within budget* — the claim
   actually under test.
2. **Structural sync** — when a poll would be redundant because the
   mechanism itself is synchronous: GenServer `call` to the owning process,
   ETS owned by the tested process, `async: false` on the one module that
   must not race siblings.

Where a sleep is unavoidable (the poll loop itself sleeps between passes),
the sleep lives inside the one audited poll implementation, bounded by its
deadline — never scattered across call sites.

### Sub-law: ratio fences for duration claims

When the claim under test is about duration (a leak fence), absolute ms
bounds are banned for the same reason fixed sleeps are. An absolute bound
equal to the leaked operation's own cost is the weakest possible placement:
it fences exactly the first leaked sleep and nothing else, and it is
load-bound. Witnessed: the 100ms absolute bound on fence-10 was a
PERSISTENT-FLAKE under parallel scheduler load (clean refusal at 129ms);
250ms fixed it only by hugging the retry constant
(`@start_retry_delay_ms`, `lib/smalt/affidavit/wasm_engine.ex:90`). The
lawful form is a **relative ratio fence** against an independent,
sleep-free-by-construction baseline — paired rounds, min-of-N. Full
analysis and drop-in conversion: `fence10-ratio.md`. In-repo precedent:
`test/amqp/fuzz_test.exs` lens-2 (clean ratio ~1.12-1.3, quadratic mutant
22.9-36.1, bound 3.0; map lens clean ~1.12, mutant ~1.7, bound 1.4).

## Law 2 — Production side: sleeps only as SCHEDULING

In `lib/`, `Process.sleep/1` is permitted only as **SCHEDULING**: a timer
modeling a real-world interval in which the process genuinely has nothing
to do until it elapses. The lawful alternative for every other use:

- **Retries** → let it crash + supervision restart, or `Process.send_after`
  backoff timers driven by a state machine — never a blocking sleep.
- **Readiness/wait coordination** → monitors, GenServer `call`/`reply`,
  `handle_continue`. Readiness is a state-machine transition on an event,
  never a clock expiry. Readiness by clock is a race that has not fired yet.
- **Start-order races** → supervision ordering, named-process `:await`, or
  a bounded poll on a real observable (same discipline as Law 1, in the one
  audited implementation).

### Current `lib/` census (2026-10-18) and required classification

Six sleep sites. Each must carry a classification under the gate (Law 3);
anything not SCHEDULING/POLL-STEP is a violation and a repair work order.

| Site | Context | Class | Lawful form |
|---|---|---|---|
| `lib/smalt/arm_gateway/router.ex:2259` | `poll_finops/1`: 4× `sleep(100)` polling `Code.ensure_loaded/1` on the request path | VIOLATION (RETRY-WAIT) | `handle_continue` chain, or `send_after` timer if truly background |
| `lib/smalt/enclave/doctor.ex:183` | `sleep(10)` settle delay after `lro_retention_ms 0` env write, before `Sweeper.eviction_pass()` | VIOLATION (SETTLE-DELAY) | make the pass read env synchronously, or poll until eviction observed |
| `lib/smalt/enclave/doctor.ex:259` | LRO terminality poll: 20ms step, deadline-checked each pass, typed raise on expiry | SCHEDULING (POLL-STEP) | bounded poll; candidate to fold into the shared poll primitive with a monotonic deadline |
| `lib/smalt/enclave/state.ex:165` | LRO destroy `poll_loop`: `sleep(@lro_poll_ms)` on non-202, attempt-bounded | SCHEDULING (POLL-STEP) | same; attempt bound → monotonic deadline at migration |
| `lib/smalt/affidavit/wasm_engine.ex:99` | `start_with_retry/2`: 250ms blocking retry sleep inside `start_link` — the leak fence-10 fences | VIOLATION (RETRY-BLOCK) | `send_after` backoff from the init state machine, or let it crash + supervisor restart |
| `lib/smalt/pplan/task.ex:154` | `wait_table/1`: `sleep(1)` spin until an ETS table appears — start-order race resolved by time (typed `:badarg` on expiry — good bound, wrong mechanism) | VIOLATION (START-ORDER WAIT) | creator signals via naming/registry path, or bounded observable poll |

Net: 2 POLL-STEP sites, 4 violation roots (5 files; one shared cause —
each substitutes time for an observation available through structure).
This census is the gate's seed classification table; it must not be
grandfathered silently.

## Law 3 — Enforcement: sleep-leak gate

Extend the leak court, or add `scripts/sleep_gate.py` (stdlib-only,
fail-closed per `gates/common.py` contract; wired via
`justfile.d/NN-sleep.just` into verify_all after naming-sweep; exit 0/1):

- `test/`: fail every `Process.sleep` **except inside the audited poll
  implementations** (allowlist today: the four per-suite poll helpers;
  after the collapse lands: `test/support/assert_eventually.ex` only).
  Allowlist growth is a reviewed diff, never silent.
- `lib/`: fail every `Process.sleep` whose site lacks an adjacent
  `# SLEEP-CLASS: SCHEDULING` (or `POLL-STEP`) annotation. Unclassified
  sites fail; annotation removal fails; annotation is audited against the
  census table above.

Annotation format:

```elixir
# SLEEP-CLASS: SCHEDULING — models the real-world poll interval; not a
# readiness/wait coordination.
Process.sleep(@lro_poll_ms)
```

Non-vacuity contract (a gate that cannot fail is the failure), shim-court
protocol on a scratch copy — BEFORE (clean tree, gate PASS) → SHIM (insert
an unclassified `Process.sleep(100)` into a test file and into `lib/`,
marked `SHIM-COURT`) → AFTER (gate must REFUSE both) → RESTORE (sha256
byte-exact, fail-closed). A gate that accepts the shims exits 1 as
`VACUOUS GATE`. Pair with the budget gate (`budget-gate.md`) for the
timing-instrument half: a test near its budget is a review signal, not
something to pad with hysteresis.

## Evidence chain

- **fence-10** (`test/affidavit_wasm_failclosed_test.exs:545-558`): the
  absolute 250ms bound flaked as a 100ms bound under load; the ratio
  conversion (min-of-5 paired rounds vs a sleep-free baseline, bound 3.0)
  keeps the same fenced class (one leaked retry sleep → RED) without the
  load sensitivity. `rewrite-drafts/fence10-ratio.md`.
- **401 cluster (FLAKE_LEDGER F8,
  `docs/jira/v26.10.17/FLAKE_LEDGER.md`)**: 13 modules, 75 failures
  (C4Blob 19, C2Keyvault 15, PolicyRbac 12, ...), witnessed at seed 71461
  (`receipts/r236-court-run1-red-75.md`). Root cause
  (`receipts/i21d-store-clear-async.md`): `management_rpc_test.exs` was the
  tree's only async module wiping shared ETS tables in setup; wipes raced
  sibling enqueues/dequeues and cascaded into 401/404 setup artifacts.
  Fix: structural sync (`async: false`), not longer sleeps — r246 warm-up
  leg: 2655 tests, 0 failures. The doctrine in miniature.
- **Atom flood (i22)**: `receipts/i22-atom-pressure.md`,
  `receipts/i22-fuzz-atom-fix.md`; the `atom_count` window measurement
  fence was retired in commit `885c451` because structural asserts
  (`map_size == 5001` + per-key `is_binary/1`, fuzz_test.exs:595-604)
  proved zero atom minting race-free — structure replaced time, again
  (`fence10-ratio.md` §1).
- **LRO races (i21/i22)**: `sweep_until_terminal/3` (lro_test.exs:1181),
  `poll_until_succeeded/2` (arm_error_corpus_test.exs:493), the
  `resilient_clear` family — deadline-bounded polls on observables
  replaced fixed sleeps, and `AssertEventually` is their collapse
  (`assert-eventually.ex.md`).

## Adoption order

1. Land `AssertEventually`; collapse the four per-suite helpers onto it.
2. Land the sleep gate seeded with the census classifications above; the
   violation sites become repair WOs.
3. Land the fence-10 ratio conversion (first application of the ratio-fence
   sub-law); vacuity probe per `fence10-ratio.md` §2 before landing.
4. Gate joins the `just court` stage table after naming-sweep.
5. Repair WOs for the violation sites (structure replaces time).
6. Promote this draft to `~/.claude/rules/no-sleep-doctrine.md` only after
   the gate is landed and non-vacuous; the harness-edit OOD-split court
   (C22) applies — a rule edit needs an out-of-family falsifier receipt.
