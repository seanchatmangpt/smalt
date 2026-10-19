# i25: atom_bridge test-harness teardown noise

Standing: ALIVE
Lane: i25 (w15-review repair candidate)
Scope: test/amqp/atom_bridge_test.exs (fixture) + minimal typed-error routing in lib/smalt/messaging/amqp/atom_bridge.ex
Git: no commit (per task instruction)

## Defect (w15-review)

The test-owned accept/serve loop logged unlinked-Task teardown noise —
einval / bad_content_length CaseClause/WithClause errors when a peer reset
mid-loop.

## Baseline (pre-fix, MIX_BUILD_ROOT=_build-ft-abn)

`MIX_BUILD_ROOT=_build-ft-abn mix test test/amqp/atom_bridge_test.exs`
exit=0, `5 tests, 0 failures` — but **5,419** lines of
`[debug] [amqp-atom] request read failed: :closed` plus at least one:

```
19:09:00.180 [error] Task #PID<0.1667.0> started from #PID<0.1663.0> terminating
** (WithClauseError) no with clause matching:
    {:error, :bad_content_length}
    (smalt 26.10.16) lib/smalt/messaging/amqp/atom_bridge.ex:112: anonymous fn/1 in Smalt.Amqp.AtomBridge.split_request/1
    (smalt 26.10.16) lib/smalt/messaging/amqp/atom_bridge.ex:96: Smalt.Amqp.AtomBridge.read_request/3
    (smalt 26.10.16) lib/smalt/messaging/amqp/atom_bridge.ex:62: Smalt.Amqp.AtomBridge.serve/2
    test/amqp/atom_bridge_test.exs:81: Smalt.Amqp.AtomBridgeTest.serve_conn/2
```

Root chain: the fixture's `loop_accept` had no `:timeout` accept clause →
10s accept timeout CaseClause-crashed the acceptor task → owner death closed
every accepted socket → the per-connection `serve_loop` (which loops on
serve/2's now-unconditional `:ok`) spun on `:closed`, emitting one debug
line per pass. Separately, `content_length/1`'s `{:error, :bad_content_length}`
fell out of `split_request/1`'s `with` (else had only `:error ->`) as a
WithClauseError, and then out of `read_request/3`'s `case` as a CaseClauseError,
crashing the serve task.

## Changes

1. `test/amqp/atom_bridge_test.exs` — fixture restructured: one harness task
   runs accept → serve per listener (`accept_serve/1`); its lifecycle expects
   the teardown vocabulary — `:timeout` (idle accept, loop), `:closed`/
   `:einval`/`:enotconn`/`:notconn` (silent structured exit, same typing as
   serve/2's i22/i23) — and exits typed (`{:atom_bridge_harness_accept, _}`)
   on anything outside it. `serve_conn/2` terminates on peer death via a
   0-timeout 1-byte liveness probe (bytes buffered and handed to serve/2 as
   `buf`), so the unconditional-`:ok` serve/2 can no longer trap the loop in
   a `:closed` spin.
2. `lib/smalt/messaging/amqp/atom_bridge.ex` (i25) — typed-error routing so
   `:bad_content_length` reaches serve/2's typed-debug path instead of
   raising into the serve task:
   - `split_request/1` else adds `{:error, _} = err -> err` (was
     WithClauseError).
   - `read_request/3` case adds `{:error, _} = err -> err` clause (was
     CaseClauseError).

serve/2's guard itself is untouched (i22/i23 typing as landed).

## Validation (real output)

Baseline noise class: 5,419 debug lines + WithClauseError crash (above).

Post-fix run 1 (`MIX_BUILD_ROOT=_build-ft-abn mix test
test/amqp/atom_bridge_test.exs`): exit=0, `5 tests, 0 failures`,
CaseClause/WithClause/terminating line count: **0**. Typed debug remaining
(bounded, per-event): 1 `:bad_content_length` (the malformed-content-length
test exercising the typed path), 8 `:closed`, 4 `:timeout`.

Post-fix run 2: exit=0, `5 tests, 0 failures`, crash-noise count **0**,
identical typed-debug profile (1/8/4).

Full directory: `MIX_BUILD_ROOT=_build-ft-abn mix test test/amqp/` —
exit=0, `331 tests, 0 failures (45 excluded)`, CaseClause/WithClause/
terminating count **0**.

## Falsifier status

- Falsified (pre-fix): `grep -cE "CaseClause|WithClause|terminating"` on test
  output > 0 — witnessed at baseline.
- Closed: both post-fix runs and the full-dir run return 0 with 5/5 and
  331/331 green.

## Notes

- serve/2 returns `:ok` unconditionally, so any caller-side loop must probe
  liveness itself; the fixture's probe pattern (0-timeout recv + buf
  handoff) is the reusable shape for other harness loops over serve/2.
- `:closed` still takes the typed-debug branch (guard covers
  einval/enotconn/notconn only) — one line per peer close, bounded, typed;
  not part of the defect class.
