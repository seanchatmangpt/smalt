# i25 — lro_test elapsed-delay sleeps → BACKDATE rewrite

Standing: ALIVE (37 tests, 0 failures, x2 green)

## Order

`rewrite-drafts/mcp-ash-misc.md` §3 residual: the elapsed-delay (TIME-ADVANCE) sleeps in
`test/lro_test.exs` at (original numbering) :144/:338/:402/:651/:672/:701/:734/:1147 —
convert survivors only; the lawful rewrite per the suite's own law ("completion is a pure
function of the stored record + clock", `lib/smalt/arm_gateway/lro.ex` module doc) is to
BACKDATE `startedAtMs` via `Store.put` instead of sleeping out the LRO delay window.

## State on arrival (concurrent-lane disclosure)

- 4 of the 8 named sites had been converted mid-session by the `i25-sleeps-a` lane
  (AssertEventually poll-replaces). Disclosure: 3 of those conversions waited on a RAW
  `Store.get` for terminality with no wire poll and no sweep (the test-owned sweeper is
  `tick_ms: :manual`), so nothing ever flipped the record — they hung 5s and FAILED
  (`37 tests, 3 failures`, measured 19:06). Under the compile-freeze SLA this lane
  fix-forwarded exactly those 3 sites (:145 ROUTER-poll, :426 concurrent-polls,
  :1204 24-poll) with the same BACKDATE rewrite; the 4th (RG-delete, wire-polling
  AssertEventually) was left standing — it flips via its own wire polls and passes.
- The 4 remaining survivors (sweeper-face sites, then at `SleepWindows.lro_delay_elapse_ms`
  form) converted to BACKDATE: retention InProgress-eviction face (:697), at-rest
  terminality (:720), no-op fence (:753), sweep/poll race (:790).
- The Notifier waiter-registration sleep (~:1482) is NOT an elapsed-delay site and was
  left untouched.

## Rewrite

New private helper `backdate_op/2` — fetch the record, `Store.put` with
`startedAtMs = now - 1_000ms` (delay is 20ms in this suite, so a backdated op is due at
the next poll/sweep). All assertions verbatim; the at-rest test's pre-sweep RAW read
still asserts `InProgress` verbatim (raw reads never evaluate).

## Validation (real output)

Run 1:

```
37 tests, 0 failures
real 4.02
EXIT:0
```

Run 2:

```
37 tests, 0 failures
real 3.19
EXIT:0
```

Both runs `MIX_BUILD_ROOT=_build-ft-lrob mix test test/lro_test.exs` on a box at
load average 400+ (concurrent lanes) — wall time did not increase: the immediately
pre-edit in-session measurement was 76.2s real with `37 tests, 3 failures` (three
5s AssertEventually timeouts), and the mechanically removed deterministic sleep is
~4 x 30ms + 3 x 5s-of-dead-wait. No clean pre-existing green baseline existed to
compare against (the only pre-edit run available was already failing the colliding
lane's broken conversions), so the no-increase claim is stated as-of-session,
per the receipt-cited-counts rule.

## Scope

- `test/lro_test.exs` only. No lib changes, no git actions, no KD/GAP register flips.
