# r200g — KD-76 pk-routing witness (lane 296)

**Standing: FAIL (real defect witnessed; register NOT flipped)**

KD-76 falsifier fired against the implemented pk-routing (KD-COVERS: KD-76
markers in `lib/smalt/messaging/amqp/connection.ex`, `eh_storage_partition/3`,
`eh_pk_partition/1`, `deliver_eventhubs_aggregate/3`). Real `@azure/event-hubs`
SDK from `workspace/node_modules` (the task-named `test/sdk-smoke/node_modules`
does not carry `@azure/event-hubs`; prior lanes r200b/lane274 used
`workspace/node_modules` — disclosed).

## Method

- Lane-private substrate: `MIX_BUILD_ROOT=_build-lane296`, anonymous auth,
  fresh key, ports 39298 (AMQP) / 39299 (EH) / 39300 (ARM), aux 43928-43930
  (egress/TLS-twin/MCP; not on the falsifier path — disclosed). Lock fd closed
  (`9>&-`); lock `/tmp/smalt-lane296.lock`. Ports verified free before boot,
  verified released after (lsof clean). Harness: `/tmp/smalt-lane296/witness-run.mjs`
  (adapted from /tmp/smalt-lane274/witness-run.mjs), falsifier
  `/tmp/smalt-lane296/kd76-falsifier.cjs`.
- Expected partition for `pk-b`: md5("pk-b")[0] % 2 = **0** (computed
  independently in python, matches `eh_pk_partition/1`).

## Embedded output (falsifier run, exit 1)

```
[witness-run] substrate up on 39298/39299/39300 (aux 43928/43929/43930) after 1505ms
[step1] sent 3 events with partitionKey="pk-b" (md5("pk-b")[0]%2 -> expected partition 0)
[FAIL] step2: expected partition 0 received all 3 pk-b events — got=[]
[PASS] step2: other partition received none of them — got=[]
[PASS] step2: every delivered event carries partitionKey=pk-b — pks=[]
[FAIL] step2: hash-deterministic (md5 first byte mod 2) — routing rule confirmed
[PASS] step3: hub-address receiver got all 3 pk-b events (aggregation) — got=["kd76-pk-b-0","kd76-pk-b-1","kd76-pk-b-2"]
[PASS] step3: hub-address events carry partitionKey=pk-b — pks=["pk-b","pk-b","pk-b"]
[step4] sent 2 unkeyed events
[PASS] step4: partition-scoped receivers do NOT see unkeyed hub sends (old behavior) — seen=[]
[PASS] step4: unkeyed events still retrievable via bare-hub receiver — got=["kd76-unkeyed-0","kd76-unkeyed-1"]
[FAIL] confirm: receiver at kd76-hub/ConsumerGroups/$Default/Partitions/0 sees pk-b events (classification probe) — got=[]
[kd76-falsifier] RESULT: FAIL (3 failure(s))
```

## Verdict detail

- **Step 1** (send 3 keyed events): OK.
- **Step 2 FAIL**: SDK `subscribe("0")` / `subscribe("1")` (partition-scoped,
  $Default consumer group) received **zero** events. The pk-b events were
  stored (step 3 proves retrievability), but partition-scoped consumers
  cannot read them.
- **Step 3 PASS**: raw-rhea receiver on hub address `kd76-hub` receives all 3
  pk-b events, each with `partitionKey="pk-b"` — aggregation and annotation
  preservation work.
- **Step 4 PASS**: unkeyed sends keep old behavior (invisible to partition
  receivers, retrievable via bare-hub receiver).
- **Confirmation probe FAIL**: a receiver at
  `kd76-hub/ConsumerGroups/$Default/Partitions/0` also receives zero events.

## Root cause (source-level, unambiguous)

`eh_hub_address?/1` in connection.ex:

```elixir
defp eh_hub_address?(address) when is_binary(address),
  do: not String.contains?(address, "/partitions/")
```

The real SDK's partition-scoped consumer attaches at
`{hub}/ConsumerGroups/$Default/Partitions/{n}` — capital-P `Partitions`, no
lowercase `/partitions/` substring (eventhubConnectionConfig.js:64-70,
`createReceiverAddress`), so the link is misclassified as a HUB link.
`deliver_eventhubs/2` routes it to `deliver_eventhubs_aggregate/3` with
`hub = eh_partition(addr) = "0"`, producing nonsense sources
`0/partitions/0`, `0/partitions/1`, `0` — zero events delivered. This is a
**regression introduced by the KD-76 refactor** of the partition-scoped
receiver path that previously worked (r200b / GAP-A2-01 witness passed
subscribe("0") against the same SDK).

## Fix hint (for the owner lane)

Classify on the partition-id terminal segment rather than substring case:
e.g. match the link address against `.../Partitions/{n}` (case-insensitive
`partitions` segment, ConsumerGroups segment tolerated) or route
`deliver_eventhubs_partition/3` when the address's last path segment is a
pinned partition id and the hub name is derived by stripping the
`ConsumerGroups/.../Partitions/n` suffix.

## Artifacts

- Harness: `/tmp/smalt-lane296/witness-run.mjs`, `/tmp/smalt-lane296/kd76-falsifier.cjs`
- Substrate log: `/tmp/smalt-lane296/logs/witness-substrate.log`

## Next

- KD-76 remains OPEN. Register not flipped (per lane contract). The owner
  lane should repair `eh_hub_address?/1` / `eh_partition/1` ConsumerGroups
  handling and re-fire this falsifier: `flock -n /tmp/smalt-lane296.lock node /tmp/smalt-lane296/witness-run.mjs` (exit 0 = repaired).
