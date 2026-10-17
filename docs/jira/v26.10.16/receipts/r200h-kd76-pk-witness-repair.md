# r200h — KD-76 pk-routing witness REPAIR (lane 297)

**Standing: PASS (witness re-fired green post-fix; register NOT flipped —
next registrar pass flips on postdate witness per lane contract)**

Repairs the regression r200g witnessed (standing FAIL). Both verification
gates green:

1. Witness re-fire: `flock -n /tmp/smalt-lane296.lock node
   /tmp/smalt-lane296/witness-run.mjs` → **exit 0**, all 11 checks PASS
   (output embedded below).
2. `MIX_BUILD_ROOT=_build-lane297 mix test --include amqp_wire
   test/amqp/event_hubs_test.exs` → **33 tests, 0 failures**.

## Fix (lib/smalt/messaging/amqp/connection.ex)

The lowercase-substring classifier (`String.contains?(address,
"/partitions/")`) misrouted the real SDK partition-consumer address
`{hub}/ConsumerGroups/$Default/Partitions/{n}` (capital P, two extra
segments) onto the aggregate path, where `hub = eh_partition(addr)` =
the whole tail → nonsense sources → zero events to partition-scoped
receivers. Replaced with a structural, case-insensitive classifier:

- `eh_partition_scope/1` — segment-shape match, case-insensitive on the
  partitions segment only: `{hub}/Partitions/{n}`,
  `{hub}/ConsumerGroups/{cg}/Partitions/{n}` (with or without the
  `/eventhubs/` prefix), legacy `/eventhubs/{hub}/partitions/{n}`.
  Returns `{hub, partition}` or nil (entity-level → aggregate).
- `deliver_eventhubs/2` — partition-scoped links now deliver via
  `deliver_eventhubs_partition/3` with the canonical lowercase storage
  key `"#{hub}/partitions/#{p}"`; hub-address links keep the KD-76
  aggregate path (pinned ["0","1"] + bare-hub key).
- `eh_storage_partition/3` — symmetric sender-side normalization: a
  pk-stamped send is pk-routed ONLY from a hub-address sender (a direct
  partition send now honors the pinned partition — previously the
  capital-P form was misclassified as hub and pk-routed, contradicting
  the pinned partition); any partitions-tail sender stores under the
  same canonical lowercase key its receivers read.
- `eh_hub_address?/1` retired (unused after the refactor).

Regression tests added in `test/amqp/event_hubs_test.exs`
(KD-76 describe, `@tag :amqp_wire`, the REAL capital-P wire forms):

1. `r200h: SDK capital-P partition receivers (.../ConsumerGroups/$Default/
   Partitions/{n}) get pk-routed events` — hub-address pk send, receivers
   at capital-P SDK form on both partitions + hub receiver; exactly one
   capital-P receiver + hub get the event, x-opt-partition-key round-trips.
2. `r200h: capital-P direct-partition send meets capital-P receiver at the
   same storage partition` — sender pinned via `{hub}/Partitions/1`
   capital form; only the matching capital-P consumer-form receiver sees it.

## Embedded output — witness re-fire (exit 0)

```
EXIT:0
[witness-run] substrate up on 39298/39299/39300 (aux 43928/43929/43930) after 2008ms
[step1] sent 3 events with partitionKey="pk-b" (md5("pk-b")[0]%2 -> expected partition 0)
[PASS] step2: expected partition 0 received all 3 pk-b events — got=["kd76-pk-b-0","kd76-pk-b-1","kd76-pk-b-2"]
[PASS] step2: other partition received none of them — got=[]
[PASS] step2: every delivered event carries partitionKey=pk-b — pks=["pk-b","pk-b","pk-b"]
[PASS] step2: hash-deterministic (md5 first byte mod 2) — routing rule confirmed
[PASS] step3: hub-address receiver got all 3 pk-b events (aggregation) — got=["kd76-pk-b-0","kd76-pk-b-1","kd76-pk-b-2"]
[PASS] step3: hub-address events carry partitionKey=pk-b — pks=["pk-b","pk-b","pk-b"]
[step4] sent 2 unkeyed events
[PASS] step4: partition-scoped receivers do NOT see unkeyed hub sends (old behavior) — seen=[]
[PASS] step4: unkeyed events still retrievable via bare-hub receiver — got=["kd76-unkeyed-0","kd76-unkeyed-1"]
[PASS] confirm: receiver at kd76-hub/ConsumerGroups/$Default/Partitions/0 sees pk-b events (classification probe) — got=["kd76-pk-b-0","kd76-pk-b-1","kd76-pk-b-2"]
[kd76-falsifier] RESULT: PASS (0 failure(s))
```

(Pre-fix re-fire earlier this session reproduced r200g's FAIL verbatim —
exit 1, 3 failures — so the flip is non-vacuous.)

## Embedded output — wire suite

```
$ MIX_BUILD_ROOT=_build-lane297 mix test --include amqp_wire test/amqp/event_hubs_test.exs
.................................
Finished in 0.9 seconds (0.00s async, 0.9s sync)
33 tests, 0 failures
```

`mix compile --warnings-as-errors` clean on the lib file.

## Artifacts

- Post-fix witness log: `/tmp/smalt-lane296/logs/witness-postfix.out`
- Pre-fix (baseline FAIL) log: `/tmp/smalt-lane296/logs/witness-baseline.out`

## Next

- KD-76 close + register flip is the registrar's pass (witness mtime >
  shim mtime now holds). `scripts/kd_flip.py --apply` per convention.
