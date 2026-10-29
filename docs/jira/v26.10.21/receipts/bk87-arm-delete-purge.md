# BK-87 — ARM queue DELETE purges the AMQP message store (BK-65 defect 2 CLOSED)

**Standing: ALIVE** — fix landed, court 4/4 PASS, non-vacuity shim proven (shimmed
fix → the zero-stale court leg fails with the exact stale-delivery signature),
regressions on the touched surfaces clean apart from 6 pre-existing failures
reproduced identically on the HEAD baseline of the edited files.

**Context: solo**

Subject: smalt `b8063f6` (coordinator snapshot commit that landed this lane's diff;
diff authored this session, not committed by the lane). Branch main, canonical
checkout `/Users/sac/smalt`, lane build root `_build-bk87`, pinned toolchain
(asdf shims: Elixir 1.20.4-otp-29 / OTP 29).

## Diff

| File | Change |
|---|---|
| `lib/smalt/messaging/amqp/queue_store.ex` | New `purge_queue/1` (public, `{:ok, deleted_count}`; typed no-op `{:ok, 0}` when tables unmaterialized) + `handle_call {:purge_queue, queue}` + `do_purge_queue/1` — deletes all `:smalt_sb_messages` rows `{queue, :_}`, all `:smalt_sb_locks` rows with `:queue == queue` (token-keyed, filtered on the record field), all `:smalt_sb_sessions` rows `{queue, :_}`. Serialized through the claim/settle server — can never interleave a concurrent claim. |
| `lib/smalt/arm_gateway/router.ex` | `sweep_child_data_plane/2` gains a `Microsoft.ServiceBus/namespaces/queues` clause: `QueueStore.purge_queue(name)` then `Store.delete(:smalt_sb_queues, name)`. Purge-first order: the purge must observe the live entity, then the entity row drops so a same-name re-PUT re-provisions an EMPTY entity (KD-86's `sb_materialize_amqp` face). |
| `test/integration/bk87_arm_delete_purge_test.exs` | New court (4 tests, real Store + real in-process ARM router dispatch + real QueueStore enqueue/claim — no mocks). |

## Court

`MIX_BUILD_ROOT=_build-bk87 MIX_ENV=test mix test
test/integration/bk87_arm_delete_purge_test.exs` → **exit 0, 4 passed**:

```
Result: 4 passed
```

Legs:

1. **Zero stale deliveries** (the defect): ARM PUT ns+queue (201) → enqueue 3 →
   peek 3 → ARM DELETE (200) → entity row gone, `{:ok, []}` peek → ARM re-PUT
   same name (201) → drain == [] → fresh enqueue + claim round-trips
   byte-exact (`bk87-fresh`).
2. **Scoped purge**: queue A claimed (live message lock at DELETE time) → ARM
   DELETE → A's lock token absent (`LockManager.get == :error`), sibling queue B's
   messages untouched, ARM DELETE B → its messages also gone.
3. **Negative (unchanged face)**: ARM DELETE of a never-created queue → plain
   200, no crash, no entity materialized by the sweep.
4. **Typed no-op face**: `purge_queue` on a never-seen name → `{:ok, 0}`.

## Non-vacuity (shim mutation)

Purged the router purge clause (kept only the entity-row delete, `# SHIM-COURT
BK-87` marker), reran the court → **exit 2, 2/4 passed**, with the zero-stale
leg failing on the exact BK-65 signature:

```
1) test ARM DELETE purges messages: re-created queue has ZERO stale deliveries
   ...
   right: [ %{body: "bk87-stale-1", ...}, ...]  (stale deliveries drained)
```

Restored byte-exact (`sha256sum -c` → `OK`).

## Regression sweep

`MIX_BUILD_ROOT=_build-bk87 MIX_ENV=test mix test` over 10 SB/ARM/queue files
(`sb_topic_fanout`, `kd51_sb_atom_https`, `kd155_delete_framing`,
`kd156_sb_shape`, `kd134_requester_delivery`, `queue_message_ct`, `sb_arm_rules`,
`t27lq_list_queues_feed`, `namespace_put`, `store_partition_wire_regression`)
→ 35/41, **6 failures all pre-existing**: reproduced identically (same 6 test
names) on the HEAD versions of the edited files (snapshot-swap baseline run,
exit 2, 8/11) — `kd155_delete_framing` (3, wire/framing tier) and
`store_partition_wire_regression` legs 2/4a/4b (3). Not session-introduced;
not touched by this diff.

## Commands / exits

| Command (cwd `/Users/sac/smalt`, `PATH` prefixed `~/.asdf/shims`) | Exit |
|---|---|
| `MIX_BUILD_ROOT=_build-bk87 mix compile` | 0 (warnings only) |
| `MIX_BUILD_ROOT=_build-bk87 MIX_ENV=test mix test test/integration/bk87_arm_delete_purge_test.exs` | 0, 4 passed |
| shim run, same command | 2, 2/4 (zero-stale leg FAIL = non-vacuity) |
| `sha256sum -c /tmp/bk87-router.sha` | OK (byte-exact restore) |
| 10-file regression sweep | 2, 35/41 — 6 pre-existing (baseline-confirmed) |
| baseline run (HEAD router/queue_store), `kd155` + `store_partition` files | 2, 8/11, same 6 failures |

## Scope notes

- Topic/subscription ARM DELETE (`sb_child_delete`) still orphans message rows
  to the sweeper — out of this lane's ownership (different delete arm); same
  purge belongs there if the KD register wants it.
- Namespace-level ARM PUT returning 202 (BK-65 defect 3) untouched.
- BK-65 defect 2 said 1–2 stale deliveries; the court enforces the stronger
  invariant: **zero** stale deliveries on the re-created generation.
