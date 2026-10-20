# No-Sleep Doctrine (reference)

> Rationale and evidence trail: `docs/explanation/no-sleep.md`.

Status: LANDED (project doc, v26.10.18 B8; promoted from
`docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md`). Enforcement:
`scripts/sleep_gate.py` via `just sleep-gate`; non-vacuity court:
`scripts/shim_court/sleep_gate_court.sh` (`just sleep-gate-court`).

## Statement

**Process.sleep is not an acceptable test or production methodology.**

A sleep coordinates nothing: it guesses that time will substitute for an
observation. In tests it buys flake-or-slowness; in production it buys
races — the slept-for condition arrives early, late, or never. Time is not
a proxy for state. The correction in every case: **observe, don't
wait-and-hope.**

Framing (Armstrong/Valim/Daniel): let it crash — supervision owns retries;
explicit state machines own readiness; the runtime owns time.

## Law 1 — Test side: poll observables

In `test/`, `Process.sleep(N)` as a coordination step is banned. Lawful
forms:

1. **Bounded polls on observables** — `SmaltTest.AssertEventually.eventually/2`
   (pre-reset `test/support/assert_eventually.ex`, RETIRED@64f6099; successors:
   `test/internal/poll_helper.exs` + `verification/{ts,py}/harness/poll.*`) polls a real observable on a
   monotonic deadline with typed immediate-fail on unexpected shape.
2. **Structural sync** — GenServer `call`, ETS owned by the tested process,
   `async: false` where a sibling must not race.

Where a sleep is unavoidable (the poll loop itself sleeps between passes),
the sleep lives inside the one audited poll implementation, bounded by its
deadline — never scattered across call sites.

### Sub-law: ratio fences for duration claims

Duration claims (leak fences) use **relative ratio fences** against an
independent sleep-free baseline (paired rounds, min-of-N), never absolute
ms bounds — an absolute bound hugging the leaked operation's own cost is
load-bound (witnessed: fence-10 100ms → PERSISTENT-FLAKE; 250ms fixed it
only by hugging `@start_retry_delay_ms`). In-repo precedent:
`test/amqp/fuzz_test.exs` (RETIRED@64f6099) lens-2 (clean ~1.12-1.3, mutant 22.9-36.1,
bound 3.0).

### B1: inherent time-advance (annotated exception)

Some sleeps cross a real time window (rate-limit second boundary, lock
expiry, LRO retention) where the condition under test IS time; no
observable can be polled. These are admitted only with an adjacent
`# SLEEP-CLASS: TIME-ADVANCE` annotation naming the window (a reviewed
diff, never silent).

## Law 2 — Production side: SCHEDULING only

In `lib/`, `Process.sleep/1` only as SCHEDULING (a real-world interval in
which the process has nothing to do until it elapses). Otherwise:

- **Retries** → supervision restart or `send_after` backoff timers, never
  a blocking sleep.
- **Readiness/wait coordination** → monitors, `GenServer.call`,
  `handle_continue`; readiness is a state-machine transition on an event,
  never a clock expiry.
- **Start-order races** → supervision ordering, named-process `:await`,
  bounded observable poll in the one audited implementation.

## Law 3 — Enforcement: the sleep gate

`scripts/sleep_gate.py` (stdlib-only, fail-closed: unreadable file, zero
files scanned, or out-of-repo path without `--as=`, exits 1).

- `test/`: every `Process.sleep` fails unless (a) inside an audited poll
  implementation (`test/internal/poll_helper.exs` or a function in
  `AUDITED_POLL_FNS` — growth is a reviewed diff), (b) a `:infinity` park
  (process fixture), or (c) annotated `# SLEEP-CLASS: TIME-ADVANCE`.
- `lib/`: every `Process.sleep` fails unless annotated with a census class:
  `# SLEEP-CLASS: SCHEDULING | POLL-STEP | SIGNALABLE-PENDING-REDESIGN |
  CONTRACT` (adjacent comment; annotation removal re-fails the site).

Non-vacuity (shim-court protocol): BEFORE clean tree PASSES → SHIM injects
an unclassified sleep (marker `SHIM-COURT`) → AFTER the gate REFUSES →
RESTORE byte-exact (sha256 fail-closed). A gate that accepts the shim exits
as `VACUOUS GATE`.

## Current classification (census refreshed 2026-10-19 @ 6681746)

lib/ (three sites):

| Site | Class | Note |
|---|---|---|
| `lib/smalt/enclave/doctor.ex:186` (eviction settle delay) | SIGNALABLE-PENDING-REDESIGN | settle-delay removal WO |
| `lib/smalt/enclave/doctor.ex:265` (`do_poll` step) | SIGNALABLE-PENDING-REDESIGN → POLL-STEP candidate | fold into LRO.await shared poll primitive |
| `lib/smalt/enclave/state.ex:169` (`poll_loop`) | SIGNALABLE-PENDING-REDESIGN | **inverted predicate fixed 2026-10-18** (slept after terminal, polled hot on 202) |

The `arm_gateway/router.ex` `poll_finops`, `affidavit/wasm_engine.ex`
`start_with_retry`, and `pplan/task.ex` `wait_table` rows are gone: the lib
redesign (`docs/jira/v26.10.18/rewrite-drafts/lib-redesign-wasm-lro.md`)
removed those sleeps (router poll went signal-driven via `LRO.Notifier`,
the wasm start retry moved out of the module).

test/ B1 TIME-ADVANCE annotated sites (20): amqp/connection_test.exs x5,
enclave-testbed/enclave_testbed.exs x2, compliance/c1_arm.exs x2, and one
each in affidavit_wasm_failclosed, amqp/sweeper_test, arm_error_corpus,
data_plane/audit_planes, lro_test, mcp_wire, pplan_test,
smalt_arm_gateway_test, smalt_ets_baseline_identity,
smalt_ets_composite_identity, support/sleep_windows.ex.

## Adoption order

1. `AssertEventually` — landed (pre-reset `test/support/assert_eventually.ex`, RETIRED@64f6099; successor `test/internal/poll_helper.exs`).
2. Sleep gate seeded with the census — landed.
3. Fence-10 ratio conversion (see `rewrite-drafts/fence10-ratio.md`).
4. Gate green + enforcement: `just sleep-gate` enforces (exit 0 on the
   current tree, 0 unclassified across 330 files). `scripts/verify_all.sh`
   still carries the legacy opt-in branch — it loud-skips the stage with
   the live violation count unless `SLEEP_GATE_ENFORCE=1` — pending a
   default-flip of that var; `just sleep-gate` is the enforcement surface
   today.
5. Repair WOs: drained — 0 unclassified test/ sites remain; the 3 lib
   SIGNALABLE-PENDING-REDESIGN redesigns (above) are the only open items.
6. Promote to `~/.claude/rules/no-sleep-doctrine.md` only after the gate
   enforces green (gate landed + non-vacuous + violations repaired); the
   C22 harness-edit OOD-split court applies.

## AZB-21 extension (v26.10.18): gate green + burn-script scope

The gate enforces green on the tree (`just sleep-gate` exit 0, 0
unclassified): every remaining site is typed via
`scripts/sleep_gate_classes.json` (audited bounded-poll files/functions,
each with a reason) or an adjacent `# SLEEP-CLASS: <TIME-ADVANCE|POLL-STEP>`
(test) / census-class (lib) annotation. Scope additions: `docker/burn/*.sh`
literal `sleep [0-9]` (no annotation escape — burn scripts pace via their
own loops), `:timer.sleep` (treated as Process.sleep), and same-line
`after <integer> ->` delay receives. Matches inside string literals are
fence fixtures, not call sites. Non-vacuity: `just shim-court sleep_gate`
now runs four legs (test, lib, burn-script, dual-injection naming both —
the AZB-21 anti-vacuity, witnessed).
