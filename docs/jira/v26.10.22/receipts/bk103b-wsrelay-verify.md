# BK-103b — WsAmqpRelay flow-frame verify (verification lane)

**Standing: PARTIAL_ALIVE — premise rot.** The BK-103 order names a
"flow-frame fix" in `lib/smalt/messaging/ws_amqp_relay.ex`; no such defect
exists on disk. The relay is domain-blind byte-shuffle by law (its own
moduledoc: "no AMQP framing interpretation beyond WS/TCP framing itself"),
so it holds no link credit and has no flow-frame accounting to fix. The
credit law lives in `lib/smalt/messaging/amqp/connection.ex` — §2.7.4
absolute link-credit (`credit = flow.delivery_count + flow.link_credit -
delivery_count`, delivery-count cancellation), `@max_link_credit 10_000`
clamp, rhea `delivery_count` MUST-pinned reply flow — and is already
witnessed by the relay e2e court. No additional fix was required or made.
The relay's only in-flight edit (a doc typo) was committed by the BK-58
lane mid-session (73e882e); working tree for the relay is clean.

**Context: solo** (MIX_BUILD_ROOT=_build-bk103b, repo-pinned Elixir
1.20.4-otp-29 via ~/.asdf shims — homebrew elixir 1.19.5 refuses :smalt).

## (1) Solo run — required gate

```
$ MIX_BUILD_ROOT=_build-bk103b mix test test/internal/ws_amqp_relay_test.exs
Running ExUnit with seed: 691765, max_cases: 32
..
Finished in 2.6 seconds (0.00s async, 2.6s sync)
Result: 2 passed        # exit 0
```

## (2) BK-82-carried EH e2e leg

Not in this file. The only EH e2e leg here is the BK-58 witness
("EH publish -> consume end-to-end through the relay", line 206) — which
is itself the full credit-path exercise: client `flow(link_credit: 10)`
on both links crosses the relay as bytes, the EH listener delivers
credit-first on flow (KD-115), drain-to-transfer, payload integrity
asserted. Green in the run above. BK-82 (sync e2e auth court) is a
workspace engine court, already ALIVE per 4ec3967.

## (3) Fix required?

No — UNSUPPORTED(no such defect). See standing line.

## (4) Regression — amqp tests touching the relay

```
$ MIX_BUILD_ROOT=_build-bk103b mix test test/internal/internal_tier_census_test.exs
Result: 2/6 passed, Failed: 4 tests
```

All 4 failures are **pre-existing, other-lane drift**, not relay-related
and not session-introduced: the census population fence flags
`bk101_g3_seam_probe_test.exs` and `bk85_seal_invariant_court_test.exs`
(new files from the BK-101/BK-85 lanes, not yet registered in the census
allowlist / status-literal rules). Owning lanes must register them; this
lane does not own `internal_tier_census_test.exs`.

## Falsifier status

The order's falsifier ("test still reds / fix incomplete") is discharged
by the 2/2 green run plus the on-disk audit: there is no relay-side
credit state whose corruption could red the suite. BK-103 as a relay
flow-frame work order closes as premise rot (same class as BK-101 G3,
78bcedf).

## Files

- `lib/smalt/messaging/ws_amqp_relay.ex` — audited, unchanged by this lane
  (typo fix committed at 73e882e by the BK-58 lane)
- `test/internal/ws_amqp_relay_test.exs` — green, unchanged
- `lib/smalt/messaging/amqp/connection.ex` — audited, credit law lives here

Not committed (per lane contract).
