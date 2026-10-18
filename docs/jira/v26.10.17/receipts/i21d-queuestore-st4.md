# i21d — QueueStore ST4 renew/sweep court T1 classification

- **Date**: 2026-10-17
- **Lane**: i21d
- **Subject**: `test/amqp/queue_store_test.exs:590` "ST4 renew/sweep court" — one witnessed T1 failure under load: row read `:available` where `:locked` expected.
- **Build root**: `MIX_BUILD_ROOT=_build-ft-qs`

## Context: solo

Solo run 3x before any edit (`mix test test/amqp/queue_store_test.exs`, tag `:amqp_wire` excluded):

```
=== RUN 1..3 ===
Finished in 1.4 seconds (0.00s async, 1.4s sync)
52 tests, 0 failures
exit=0   (3/3)
```

**Verdict: CONTENTION** — pure test-side timing assumption, no product defect.

## Timing assumption named

Original test: `lock_duration_ms: 100` (the clamp floor, `LockManager.clamp_duration` clamps to 100..30000), renew at +50ms → renewed expiry +150ms, sweep at +110ms. Deadlines: sweep must land in the (100, 150) window — **~40ms of deadline slack**. Under load, scheduler jitter past the renewed expiry legitimately expires the lock; `QueueStore.sweep/0` then correctly re-queues and the row reads `:available`. The assertion is correct contract; the deadline was too tight.

Also verified in-product: `LockManager.renew_lock` refuses after original expiry (`{:error, :lock_lost}`) — renew must complete before the original expiry, and a sweep landing early (before original expiry) is a no-op and harmless to the assertion. Only one fatal direction: sweep past renewed expiry.

## Fix applied (test-side, minimal, comment-cited)

`test/amqp/queue_store_test.exs` ST4 test body only:

- `lock_duration_ms: 100 → 1000` (lawful: clamp is 100..30000 floor, not ceiling)
- renew at ~+700ms (300ms budget before the +1000ms original expiry — the boundary case renew-at-expiry was caught and corrected during this session, see "intermediate failure" below)
- sweep at ~+1200ms, inside (1000, 1700): past original expiry (preserves test intent: the pre-fix bug reclaimed at original expiry) and 500ms before renewed expiry; sweep-early jitter is harmless
- comment block cites `clamp_duration` and `renew_lock` semantics

## Intermediate failure witnessed and corrected (honesty record)

First slack attempt (renew at `Process.sleep(1000)`, exactly at expiry) failed solo with `{:error, :lock_lost}` — renew-at-expiry boundary. Verbatim:

```
  1) test concurrency (ST4 court) sweep/0 does NOT reclaim a renewed message lock (renew mirrors into message row) (Smalt.Amqp.QueueStoreTest)
     test/amqp/queue_store_test.exs:590
     match (=) failed
     code:  assert {:ok, _} = LockManager.renew(lock.lock_token, System.system_time(:millisecond))
     left:  {:ok, _}
     right: {:error, :lock_lost}
     stacktrace:
       test/amqp/queue_store_test.exs:607: (test)

Finished in 1.3 seconds (0.00s async, 1.3s sync)
1 test, 1 failure (51 excluded)
```

Corrected to renew at ~+700ms. No production code touched.

## Verification

- 6x full-file `mix test test/amqp/queue_store_test.exs` → `52 tests, 0 failures` each
- Targeted `mix test test/amqp/queue_store_test.exs:590` → `1 test, 0 failures (51 excluded)`
- All runs `MIX_BUILD_ROOT=_build-ft-qs`, no git operations.

## Standing

**ALIVE** (test timing-heap widened; product code untouched; the witnessed load failure is attributed to deadline slack, not a product race — the renew-mirror fix itself is asserted correctly and holds).
