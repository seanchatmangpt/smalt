# i25 — sleeps.md §B2: `eventually_stays/2` + 4 absence-check migrations

Standing: **ALIVE**
Context: slice(multi-file batch, per embedded commands)

Window: v26.10.18 · Lane: sleeps-b2 (sb2) · Date: 2026-10-18
Subject: working tree at main, 9f4c19d (feat(planes) ...) + this lane's edits, no git actions taken.

## Scope

- `test/support/assert_eventually.ex`: added `eventually_stays/2` per
  `docs/jira/v26.10.18/rewrite-drafts/sleeps.md` §B2 — truthy poll, stability
  window (default 50 ms), flip false→true resets the clock, exceptions inside
  `fun/0` captured as false observations, typed flunk on timeout carrying
  `desc`, `:stability_ms`/`:within_ms`, and the LAST observation.
- Migrations (4 sites, per drafts; broker_facade checked current state first —
  the b2 rewrite had already replaced the two settle sleeps with structural
  proofs, so only the trailing single-instant `Process.alive?` asserts were
  survivors to convert):
  - `test/amqp/r129_session_gate_test.exs` (error-close site): sleep(50)+two
    bare asserts → `eventually_stays` on "zero rows in shadow + bare
    namespace", stability 50 ms.
  - `test/amqp/r129_session_gate_test.exs` (cleanup-detach site): sleep(50) →
    `eventually_stays` on "no `{queue, sid}` row in `:smalt_sb_sessions`"
    (the honest absence observable; `:smalt_sb_sessions` key = `{queue,
    session_id}` per `lib/smalt/messaging/amqp/lock_manager.ex` moduledoc).
  - `test/amqp/broker_facade_test.exs` (client-churn test): trailing
    `assert Process.alive?(pid)` → `eventually_stays` 50 ms stability window.
  - `test/amqp/broker_facade_test.exs` (`:amqp_wire` kill test): trailing two
    `assert Process.alive?` → one `eventually_stays` over
    listener-alive AND ConnSup-alive, 50 ms stability window.
- New typed-failure doc-test: `test/assert_eventually_test.exs` (4 tests):
  window pass, violated absence → typed flunk (message names desc, windows,
  last observation), flip-resets-clock non-vacuity, exception-as-observation.

## Verification (real output)

Build root: `MIX_BUILD_ROOT=_build-ft-sb2` (lane lease, deleted below).

Pass 1 (touched files, fresh build, default excludes — 1 excluded is the
`:amqp_wire` broker_facade test):

```
Finished in 1.8 seconds (0.00s async, 1.8s sync)
7 tests, 0 failures (1 excluded)
[exited with code 0]
```

Pass 2 (touched files + helper tests + `--include amqp_wire` so the :96-site
test actually executes):

```
11 tests, 0 failures (1 excluded)   # helper tests + both amqp files
8 tests, 0 failures                 # amqp files incl :amqp_wire
```

Exact commands, final runs:

```
$ MIX_BUILD_ROOT=_build-ft-sb2 mix test test/assert_eventually_test.exs \
    test/amqp/r129_session_gate_test.exs test/amqp/broker_facade_test.exs
11 tests, 0 failures (1 excluded)

$ MIX_BUILD_ROOT=_build-ft-sb2 mix test test/amqp/r129_session_gate_test.exs \
    test/amqp/broker_facade_test.exs --include amqp_wire
8 tests, 0 failures
```

Typed-failure doc-test witnessed (the violated-absence test asserts the exact
flunk text):

```
eventually_stays(raises forever) never held stable for 20ms within 80ms;
last observation: {:raise, :error, %RuntimeError{message: "still settling"}}
```

## Notes

- Draft called the helper `eventually_stays/3`; implemented as
  `eventually_stays/2` (fun + opts) for symmetry with the existing
  `eventually/2` — the draft's own code block is arity-2.
- Draft's B2 broker_facade plan assumed the settle sleeps still existed; they
  did not (b2 rewrite). Converted the surviving absence-shaped instant
  alive-checks instead; structural probes (fresh connect, DOWN message)
  retained unchanged.
- Sleeps.md class table remains accurate: B2 count stays 4 sites migrated.

## Cleanup

Lane build root `_build-ft-sb2` deleted at close via `just lane-clean`
(also reclaimed other orphans; sb2 line: `DELETED: _build-ft-sb2 (351156 KB)`).
