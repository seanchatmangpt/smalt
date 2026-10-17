# Receipt — R149 (sweeper raise fence)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

Session-listed as "sweeper raise fence test, 5/0". The fence is
`lib/smalt/messaging/amqp/sweeper.ex:55-61`: a sibling failure must raise and
crash-restart the GenServer instead of silently swallowing
(Process.send_after / ArgumentError mid-run class); the covering tests are the
"Sweeper" describe block in `test/amqp/broker_facade_test.exs:107`
(`:sys.suspend`/`:sys.resume` around the sweeper tick). No R149 literal marker
exists on disk; receipt written from the session-verified subject list plus
suite-level verification.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/amqp/broker_facade_test.exs
5 tests, 0 failures (1 excluded)
```

(Matches the session-claimed 5/0 exactly.)

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/amqp/broker_facade_test.exs
5 tests, 0 failures (1 excluded)
```

(Matches the session-claimed 5/0 exactly.) Standing: PASS.
