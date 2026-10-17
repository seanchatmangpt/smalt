# Receipt — R120 (w3 session-ops pytest port fix + skip rationale rewrite)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PARTIAL_ALIVE
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files (markers verified on disk)

- `smalt-cli/tests/test_w3_session_ops.py:29-32` (R120 marker): the enforce
  substrate fixture boots AMQP on 38672 (lane-private block shared with
  test_servicebus.py); the old default 38692 pointed at a never-booted substrate,
  so every test died in connect-refused and the KD guard degenerated into 4 loud
  skips.
- `smalt-cli/tests/test_w3_session_ops.py:83` (R120 rationale-update marker):
  skip rationale rewritten for KD-21 (open-frame trim crash) and companions.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ grep -n "Repair lane R120" smalt-cli/tests/test_w3_session_ops.py
29:# Repair lane R120: the enforce_substrate fixture (tests/conftest.py) boots
83:# Repair lane R120 rationale update: KD-21 (open-frame trim crash) and the
```

Standing is PARTIAL_ALIVE: the live pytest leg needs the enforce substrate on a
quiet lock (the W5/W6 docs lane already witnessed concurrent-lane runs
degenerating to "4 skipped in 1200s"); this lane did not re-run the pytest leg
and does not claim it — the port-fix markers and their grep output above are the
verified consequence on disk.
