# No-Sleep Doctrine (reference)

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
   (`test/support/assert_eventually.ex`) polls a real observable on a
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
`test/amqp/fuzz_test.exs` lens-2 (clean ~1.12-1.3, mutant 22.9-36.1,
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
  implementation (`test/support/assert_eventually.ex` or a function in
  `AUDITED_POLL_FNS` — growth is a reviewed diff), (b) a `:infinity` park
  (process fixture), or (c) annotated `# SLEEP-CLASS: TIME-ADVANCE`.
- `lib/`: every `Process.sleep` fails unless annotated with a census class:
  `# SLEEP-CLASS: SCHEDULING | POLL-STEP | SIGNALABLE-PENDING-REDESIGN |
  CONTRACT` (adjacent comment; annotation removal re-fails the site).

Non-vacuity (shim-court protocol): BEFORE clean tree PASSES → SHIM injects
an unclassified sleep (marker `SHIM-COURT`) → AFTER the gate REFUSES →
RESTORE byte-exact (sha256 fail-closed). A gate that accepts the shim exits
as `VACUOUS GATE`.

## Current classification (seed census, 2026-10-18)

lib/ (six sites):

| Site | Class | Note |
|---|---|---|
| `lib/smalt/arm_gateway/router.ex` `poll_finops` | SIGNALABLE-PENDING-REDESIGN | readiness flag redesign WO |
| `lib/smalt/enclave/state.ex` `poll_loop` | SIGNALABLE-PENDING-REDESIGN | **inverted predicate fixed 2026-10-18** (slept after terminal, polled hot on 202) |
| `lib/smalt/enclave/doctor.ex` settle delay | SIGNALABLE-PENDING-REDESIGN | settle-delay removal WO |
| `lib/smalt/enclave/doctor.ex` `do_poll` | SIGNALABLE-PENDING-REDESIGN → POLL-STEP candidate | fold into shared poll primitive |
| `lib/smalt/affidavit/wasm_engine.ex` `start_with_retry` | CONTRACT | 3 x 250ms NIF-teardown bounded retry; contract |
| `lib/smalt/pplan/task.ex` `wait_table` | SIGNALABLE-PENDING-REDESIGN | handle_continue + `:ready` handshake WO |

test/ B1 TIME-ADVANCE annotated sites (13): lro_test.exs x4, mcp_wire 956,
c1_arm 399/422, smalt_arm_gateway 1287, arm_error_corpus 477, queue_store
607/611, sweeper_test 87, enclave_testbed 610.

## Adoption order

1. `AssertEventually` — landed (`test/support/assert_eventually.ex`).
2. Sleep gate seeded with the census (this landing).
3. Fence-10 ratio conversion (see `rewrite-drafts/fence10-ratio.md`).
4. Gate joins the `just court` stage table after naming-sweep — currently
   wired into `scripts/verify_all.sh` as a LOUD SKIP with live violation
   count until the repair WOs land; export `SLEEP_GATE_ENFORCE=1` to
   enforce now.
5. Repair WOs: ~37 remaining unclassified test/ sites (A/B2/pacing classes
   from `rewrite-drafts/sleeps.md`) + the 5 SIGNALABLE-PENDING-REDESIGN
   lib redesigns.
6. Promote to `~/.claude/rules/no-sleep-doctrine.md` only after the gate
   enforces green (gate landed + non-vacuous + violations repaired); the
   C22 harness-edit OOD-split court applies.
