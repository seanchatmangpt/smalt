# i20g — c7_events PARTIAL fence freshness fix

Standing: PASS

Lane: c7 (lease: `test/compliance/c7_events.exs` ONLY). Build root `_build-ft-c7`.

## Stale premise (sweep #1, confirmed)

`test/compliance/c7_events.exs:226` — `[eh] partitions are free-form names ... (PARTIAL fence)`
asserted fresh counters `s1 == 1 and s2 == 1` against `p1 = "c7-ns/c7-hub/0"`. But EH seq
counters are per-partition state in the immortal named GenServer
`Smalt.Messaging.EventHubs.Server` and survive the per-test Store restart; the fence reused
a partition that the earlier `[eh] strictly monotonic per-partition sequence` fence had
already bumped to seq 3. Failure was run-order-dependent, not a regression in the fenced
behavior.

## Fix

Both partition ids in the PARTIAL fence are now unique per run
(`"c7-ns/c7-hub/fresh-#{System.unique_integer([:positive])}"`), so `s1 == 1 and s2 == 1`
hold regardless of run order. The fence's actual claim (free-form partition names accepted,
no 0..N fan-out enforced) is unchanged; the PARTIAL row in
`docs/compliance/C7_EVENT_PLANES.md` is untouched.

## Verification (real output)

```
$ MIX_BUILD_ROOT=_build-ft-c7 mix test test/compliance_test.exs
...
Finished in 6.8 seconds (0.00s async, 6.8s sync)
157 tests, 0 failures (16 excluded)
```

Exit 0. Full compliance corpus green corpus-wide, including the c1/c2/c4 fences carried by
other lanes' fixes. No failures remain.

No git actions taken.
