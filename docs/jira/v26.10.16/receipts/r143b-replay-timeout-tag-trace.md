# Receipt — R143b (replay timeout tag — trace result)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PARTIAL_ALIVE (trace)
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

Session-listed as "replay timeout tag, cold 112s green". Traced for a
`replay`-timeout test tag across `test/test_helper.exs` (the tag registry is the
`:amqp_wire` exclusion list — no replay/timeout tag exists), `config/*.exs`, and
keyword greps (`replay_timeout`, `replay.*timeout`) over `lib test scripts`:
no on-disk marker found. The default-excluded tag inventory on disk is exactly
`[:amqp_wire]` (see `test/test_helper.exs:10-14`), so either the tag landed
under a different name or the change did not survive to this tree.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ grep -rn "replay_timeout\|replay.*timeout.*tag" lib test config scripts 2>/dev/null
(no output)
$ grep -rn "replay" test/test_helper.exs config/*.exs
(no output)
```

No code change is claimed for R143b. The 112s cold-green claim is recorded as
session testimony only, not re-executed by this lane.

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

No on-disk marker has appeared since W7 (`grep -rn "replay_timeout" lib test
config scripts` → still no output). Per the W10 dispatch, the 112.2s cold-green
full-tier figure is cited from R143b's own pasted session output and is marked
as testimony, not re-executed by this lane. For current-tree context, the W10
full-tier re-run on `_build-lane204` is green: 1 doctest, 7 properties, 2018
tests, 0 failures (36 excluded), 432.6s wall (warm root). Standing unchanged:
PARTIAL_ALIVE (trace, session testimony only for the 112.2s figure).
