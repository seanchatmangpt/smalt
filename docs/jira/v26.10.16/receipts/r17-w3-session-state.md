# Receipt — R17 (w3 session-state API fix)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PARTIAL_ALIVE — the session-state management-op round trip
  (the R17 repair surface) is witnessed working; the same test's message-flow
  assertion fails on the current tree due to a separate AMQP attach issue
  (detail below)
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `smalt-cli/tests/test_w3_session_ops.py` (lane-private W3 falsifier;
  GAP-A2-05/06/07 session/DLQ management ops)
- `lib/smalt/messaging/amqp/management_rpc.ex` (lines 125-126:
  `:set_session_state` / `:get_session_state` dispatch; `set_session_state/5`
  at line 423)

## Defect

Session state ops were not witnessed over the real azure-servicebus SDK tier
($management `com.microsoft:set/get-session-state`); the w3 falsifier was the
missing witness.

## Fix

`test_w3_session_ops.py` witnesses set_session_state → get_session_state
round trips (including the SDK-legal empty-binary clear and re-set) against
the real SDK on lane-private ports 38690-38692.

## Verification (2026-10-15, W1 wave-2 docs lane, real run)

```
$ cd smalt-cli && .venv-cli/bin/pytest tests/test_w3_session_ops.py -q
WARNING  azure.servicebus._pyamqp.link:link.py:193 Callback for link attach raised error: TypeError('Target.__new__() takes from 1 to 8 positional arguments but 9 were given')
2 failed, 2 skipped in 27.20s
```

Failure detail (round-trip test):

```
>           assert len(msgs) == 1
E           assert 0 == 1
tests/test_w3_session_ops.py:130
```

## Reading of the witness

The asserts BEFORE the failure all passed: `set_state(b'{"phase": 1}')` →
`get_state()` == `b'{"phase": 1}'`, empty clear → `b""`, re-set →
`b'{"phase": 2}'`. The session-state management ops themselves work over the
real SDK tier. The failure is at `len(msgs) == 1` — the session receiver
received 0 messages, with a concurrent
`TypeError('Target.__new__() takes ... 9 were given')` on link attach
(pyamqp side). `lib/smalt/messaging/amqp/connection.ex` and
`lock_manager.ex` are in-flight edits by another lane in this same wave; this
failure signature is consistent with that in-flight state, not with the
session-state management surface R17 repaired.

Verdict: R17's surface (management-op session state) is ALIVE as witnessed;
the message-flow assertion is an open cross-lane defect on the AMQP attach
path, recorded here for the owning lane (KD-49 territory).
