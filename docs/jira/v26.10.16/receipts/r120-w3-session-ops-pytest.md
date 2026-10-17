# Receipt — R120 (w3 session-ops pytest substrate wiring)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** SKIP-LOUD (harness-skip; substrate provisioning contended)
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `smalt-cli/tests/test_w3_session_ops.py:29-40` — R120: the
  `enforce_substrate` fixture boots AMQP on 38672 (the lane-private block
  `test_servicebus.py` rides) instead of the never-booted 38692, so the KD
  guard can no longer degenerate into silent skips; shared-key CBS wiring
  documented in-file
- `smalt-cli/tests/conftest.py` — substrate provisioning under its own lock
  (`/tmp/smalt-substrate-cli5.lock`)

## Verification (2026-10-16, W6 docs lane, unedited output)

Two full runs, both hitting the 1200s provisioning timeout:

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_w3_session_ops.py -q -p no:cacheprovider
ssss                                                                     [100%]
4 skipped in 1200.54s (0:20:00)
[exit 0]

$ <identical re-run>
ssss                                                                     [100%]
4 skipped in 1200.37s (0:20:00)
EXIT=0
```

## Reading

Loud SKIP per the exit-code contract (3 = skip, never a fake pass): the
fixture refuses to trust a substrate it did not boot this session, and its
own boot could not take `/tmp/smalt-substrate-cli5.lock` inside the timeout —
concurrent lanes hold the cli-substrate lock (a beam IS LISTENing on 38672
during both runs, booted by another session). The recorded in-session
verification for R120 was "2 passed 2 skipped" under a quiet lock; this lane
could not reproduce that window. Re-run when the cli substrate locks are
quiet. The skip is loud and typed, not a vacuous green.
