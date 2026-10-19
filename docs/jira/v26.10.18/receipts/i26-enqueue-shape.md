# i26: azsim plane-batch enqueue return-shape (v2 soak finding)

**Standing: PASS (no-op — already resolved)**

## Finding re-check

v2-soak (`receipts/v2-soak.md` lines 46, 101) reported, at HEAD `be81187`,
`QueueStore.enqueue` returning `{:ok, 1}` vs expected `:ok` in the azsim plane
batch. Grep of the current tree:

```
$ grep -rn ":ok = QueueStore.enqueue\|:ok =.*enqueue\|enqueue.*= :ok" test -r
(no matches)
```

All enqueue assertions already match the lib contract
(`lib/smalt/messaging/amqp/queue_store.ex:197` — `@spec enqueue(...) ::
{:ok, integer()} | {:error, :capacity | :too_large | :session_required}`):

- `test/azsim/integration_plane_test.exs:40` — `assert {:ok, _} = QueueStore.enqueue(queue, "payload-1")`
- `test/azsim/integration_plane_test.exs:58` — `assert {:ok, _} = QueueStore.enqueue(queue, "poison")`
- `test/azsim/amqp_saturation_test.exs:98` — `assert {:ok, _} = QueueStore.enqueue(q, "poison-#{q}")`

The other named files (`control_plane_test.exs`, `data_plane_test.exs`,
`identity_plane_test.exs`, `topology_test.exs`; no `all_plane_test.exs`
exists) contain zero enqueue references — nothing to fix. The mismatch was
against be81187; the azsim batch landing (effd877 "sleeps A/B2/B1" et al.)
already corrected the assertions. Per Chicago, the lib shape (`{:ok, seq}`,
real sequence-number data) is the contract and the tests now assert on it.

## Validation (x2 green, MIX_BUILD_ROOT=_build-ft-enq)

Run 1:

```
$ MIX_BUILD_ROOT=_build-ft-enq mix test test/azsim/integration_plane_test.exs test/azsim/amqp_saturation_test.exs
9 tests, 0 failures (4 excluded)
[exited with code 0]
```

Run 2:

```
$ MIX_BUILD_ROOT=_build-ft-enq mix test test/azsim/integration_plane_test.exs test/azsim/amqp_saturation_test.exs
9 tests, 0 failures (4 excluded)
exit=0
```

(4 excluded = default-tagged `:amqp_wire` tier, not part of the offline suite.)

## Consequence

No source edits. v2-soak's "enqueue arity/return-shape mismatch" row for the
azsim plane batch is closed by this receipt: the enqueue face is green at
current HEAD.
