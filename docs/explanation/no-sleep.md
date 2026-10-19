# no-sleep doctrine (why)

Why `Process.sleep` is not an acceptable test or production methodology in
smalt, and the evidence trail that produced the law. The statement, the
three laws, and the current census live in `docs/NO_SLEEP_DOCTRINE.md` (the
canonical reference); this page explains the rationale.

## The core argument

A sleep coordinates nothing: it guesses that time will substitute for an
observation. In tests it buys flake-or-slowness; in production it buys
races — the slept-for condition arrives early, late, or never. Time is not
a proxy for state. The correction in every case: **observe, don't
wait-and-hope.**

Framing (Armstrong/Valim/Daniel): let it crash — supervision owns retries;
explicit state machines own readiness; the runtime owns time.

## Why a poll is not just a polite sleep

A bounded poll on an observable differs from a sleep in kind, not degree:

- It has a **deadline with a typed failure** — a poll that never sees the
  condition fails naming the observable and the last observation; a sleep
  fails later, somewhere else, with someone else's error.
- It has **backoff**, so the fast path is fast (the default
  `AssertEventually` backoff doubles 10ms → 200ms) instead of paying the
  worst-case delay on every pass.
- It carries **bits** on failure: `eventually(foo, observable: "...")`
  tells you WHAT was not observed; `Process.sleep(500)` followed by an
  assertion tells you only that an assertion failed.

The one bounded-retry primitive is `SmaltTest.AssertEventually`
(`test/support/assert_eventually.ex`); `SmaltTest.Store.resilient_clear/1`
is built on it so the tree has exactly one retry implementation.

## Why the exception (time-advance) is typed

Some conditions ARE time: rate-limit window rollover, lock expiry, LRO
retention. No observable exists before the window elapses. These sleeps are
admitted only as NAMED windows derived from their configured constants
(`SmaltTest.SleepWindows`) with an adjacent
`# SLEEP-CLASS: TIME-ADVANCE` annotation — a reviewed diff, never silent.
Banning the class outright would just drive it underground as bare
literals; naming it makes every site auditable.

The same logic admits duration-claim fences only as **relative ratio
fences** against a sleep-free baseline, never absolute ms bounds — an
absolute bound hugging the leaked operation's own cost is load-bound
(witnessed: a 100ms fence was a PERSISTENT-FLAKE; 250ms "fixed" it only by
hugging the operation's own delay). In-repo precedent: `test/amqp/fuzz_test.exs`
lens-2 (clean ~1.12-1.3, mutant 22.9-36.1, bound 3.0).

## Why a gate, not a guideline

Guidelines rot; gates re-fail. `scripts/sleep_gate.py` (`just sleep-gate`)
is stdlib-only and fail-closed: unreadable file, zero files scanned, or an
out-of-repo path without `--as=` exits 1. In `test/` every `Process.sleep`
fails unless it is inside an audited poll implementation, a `:infinity`
park, or a `TIME-ADVANCE` annotation; in `lib/` every sleep needs a census
class annotation (`SCHEDULING | POLL-STEP | SIGNALABLE-PENDING-REDESIGN |
CONTRACT`). Scope additions (AZB-21): `docker/burn/*.sh` literal
`sleep [0-9]`, `:timer.sleep`, and same-line `after <integer> ->` receives.

Non-vacuity follows the shim-court protocol: BEFORE clean tree PASSES →
SHIM injects an unclassified sleep (marker `SHIM-COURT`) → AFTER the gate
REFUSES → RESTORE byte-exact. `just shim-court sleep_gate` runs four legs
(test, lib, burn-script, dual-injection) — the anti-vacuity is witnessed,
not claimed. A gate that accepts the shim exits as `VACUOUS GATE`.

## Evidence trail

- `docs/NO_SLEEP_DOCTRINE.md` — statement, laws, lib census (six sites,
  each classified), test B1 annotated sites, adoption order.
- `docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md` — the draft
  the doctrine was promoted from.
- `docs/jira/v26.10.18/receipts/azb-21-zero-sleep.md` — gate-green receipt
  (0 unclassified sites) + scope extensions.
- `docs/jira/v26.10.18/rewrite-drafts/fence10-ratio.md` — the measured
  absolute-bound flake that produced the ratio-fence sub-law.
- `docs/jira/v26.10.18/rewrite-drafts/sleeps.md` — the 13-site B1 census
  the windows derive from.

## Adoption status

The gate enforces green on the tree (`just sleep-gate` exit 0); export
`SLEEP_GATE_ENFORCE=1` to enforce in `scripts/verify_all.sh` (currently a
LOUD SKIP with live violation count there). Repair WOs for the remaining
`SIGNALABLE-PENDING-REDESIGN` lib redesigns are tracked in the doctrine's
adoption order. Promotion to a global rule happens only after the gate
enforces green everywhere — see the doctrine file.

## See Also

- `docs/NO_SLEEP_DOCTRINE.md` (canonical statement + census)
- `docs/how-to/how-to-write-tests.md` (AssertEventually, SleepWindows)
- `docs/reference/courts.md` (shim-court protocol)
