# ets-tables

ETS table inventory. Source of truth: `lib/smalt/store.ex` `@tables`
(`Smalt.Store.table_names/0`). All core tables are `:ordered_set, :public,
:named_table, read_concurrency: true`, created idempotently by `Smalt.Store`;
keys are lowercased full ARM id strings (or id-shaped paths) so
`list_prefix/2` scans are deterministic and TF-stable.

Count: **28 core tables** (store.ex `@tables`, lines 11-39) plus **2
lazily-created `:set` tables** owned by `blob_storage.ex` that sit outside
`@tables`. (Earlier prose says 27; the on-disk list is 28.)

## Core tables (`Smalt.Store` `:ordered_set`)

| table | key convention | owning surface | cascade behavior |
|---|---|---|---|
| `:smalt_subscriptions` | subscription id | `arm_gateway/router.ex` | metadata table — control-plane root, auto-provisioned; survives destroy |
| `:smalt_resource_groups` | lowercased RG ARM id | `arm_gateway/router.ex`, `enclave/state.ex` | RG delete cascades to resources in the group (router.ex cascade, D127 decision); swept on destroy |
| `:smalt_resources` | lowercased full ARM id | `arm_gateway/router.ex`, `enclave/state.ex`, `mcp/router.ex`, `messaging/amqp/atom_bridge.ex` | reverse-topological delete (deepest path-first) through the real router; zero-residue asserted post-destroy |
| `:smalt_operations` | LRO op id | `arm_gateway/lro.ex`, `arm_gateway/lro_sweeper.ex` | metadata — terminal op records are history, not residue; survive destroy; at-rest sweeper flips terminal |
| `:smalt_cosmos_docs` | `"{db}/{coll}/{doc_id}"` | `data_plane/cosmos.ex` | data table; swept per-destroy |
| `:smalt_cosmos_lsn` | `{{0,db}}`, `{{1,db,coll}}`, `{{2,db,coll}}` tuple keys | `data_plane/cosmos.ex` | metadata (counters) — survives destroy |
| `:smalt_cosmos_pk_meta` | `"{db}/{coll}"` | `data_plane/cosmos.ex` | data table; swept per-destroy |
| `:smalt_vault_keys` | key `name`; version rows `{name, version}` | `data_plane/key_vault_actions.ex`, `data_plane/skr.ex`, `egress_router.ex`, `mcp/router.ex` | data table; swept per-destroy |
| `:smalt_vault_secrets` | secret name | `data_plane/vault_data.ex`, `arm_gateway/router.ex`, `egress_router.ex` | data table; swept per-destroy |
| `:smalt_blobs` | `"account/container/blob"` | `data_plane/blob_storage.ex`, `mcp/router.ex` | FR-6 `drop_account_data/1` sweeps by `"account/"` prefix; RG cascade may drop via container sweep |
| `:smalt_blob_containers` | `"account/container"` | `data_plane/blob_storage.ex`, `data_plane/blob_service.ex`, `egress_router.ex` | FR-6 sweep + D127: RG delete cascades container sweep; per-container DELETE remains a product gap (does not close D127) |
| `:smalt_blob_policy` | per-container policy key | `data_plane/blob_storage.ex` (`@policy_table`) | FR-6 sweep target; also lazily re-created `:set` in blob_storage (guard: `:ets.info`) |
| `:smalt_ledger_transactions` | `"{ledger}/{tx_id}"` | `security/ledger_writer.ex`, `security/confidential_ledger.ex` | data table; swept per-destroy |
| `:smalt_ledger_meta` | `{:latest/\:seq/\:created, ledger}` tuple keys | `security/ledger_writer.ex` | metadata — survives destroy |
| `:smalt_event_messages` | `"topic/id"` | `messaging/event_stream.ex` | data table; swept per-destroy; tuple-prefixed bookkeeping keys sort below binary keys in prefix scans |
| `:smalt_sb_queues` | entity name; counter `{queue, :seq}` | `messaging/amqp/queue_store.ex` | data table; swept per-destroy |
| `:smalt_sb_messages` | `{queue, seq}` | `messaging/amqp/queue_store.ex`, `lock_manager.ex` | data table; swept per-destroy |
| `:smalt_sb_locks` | lock token | `messaging/amqp/lock_manager.ex`, `sweeper.ex` | metadata — monotonic plumbing; survives destroy |
| `:smalt_sb_sessions` | `{queue, session_id}` | `messaging/amqp/queue_store.ex`, `lock_manager.ex` | metadata — survives destroy (per enclave/state @metadata_tables) |
| `:smalt_sb_tokens` | CBS token key | `messaging/amqp/connection.ex` | metadata — survives destroy |
| `:smalt_eh_partitions` | `"ns/hub/partition"`; integer cell `{:seq_counter, partition}` | `messaging/event_hubs.ex` | metadata — survives destroy |
| `:smalt_eh_checkpoints` | `{group, partition}` | `messaging/event_hubs.ex` | metadata — survives destroy |
| `:smalt_sentinel_streams` | `"{dcr}/{stream}"`; marker `{:dcr_created, dcr}` | `data_plane/sentinel.ex` | metadata — survives destroy |
| `:smalt_sentinel_rows` | `"{dcr}/{stream}/{padded seq}"` | `data_plane/sentinel.ex` | data table; swept per-destroy |
| `:smalt_purview_entities` | entity guid | `data_plane/purview_atlas.ex` | data table; swept per-destroy |
| `:smalt_purview_edges` | `"{from}/{to}/{type_name}"` | `data_plane/purview_atlas.ex` | data table; swept per-destroy |
| `:smalt_resource_graph_tokens` | token key | `data_plane/resource_graph.ex` | metadata — survives destroy |
| `:smalt_attestation_baseline` | baseline key | `security/attestation.ex` | metadata — survives destroy |

## Lazy tables (outside `@tables`, `:set`, guarded by `:ets.info`)

| table | key convention | owning surface | cascade behavior |
|---|---|---|---|
| `:smalt_blob_blocks` | block key under blob | `data_plane/blob_storage.ex:312` | FR-6 sweep target; may be un-booted — `drop_account_data` guards with `:ets.info` |
| `:smalt_blob_snapshots` | snapshot key | `data_plane/blob_storage.ex:694` | FR-6 sweep target; same guard |

## Cascade laws (the census)

Three cascade mechanisms exist; they are distinct:

1. **RG cascade** (`arm_gateway/router.ex`, D127 decision): resource-group
   delete sweeps contained resources AND blob containers in the group. This
   cascade is not an implementation of per-container DELETE — the D127
   product gap stays open (WRAP_LEDGER item 4 wording, on record).
2. **FR-6 data-plane drop** (`blob_storage.drop_account_data/1`): sweeps
   `:smalt_blob_containers`, `:smalt_blobs`, `:smalt_blob_policy`,
   `:smalt_blob_blocks`, `:smalt_blob_snapshots` by `"account/"` prefix,
   guarded per-table on `:ets.info` so un-booted lazy tables are loud-safe.
   Note: "FR-6" itself carries no on-disk referent outside receipts
   (exhaustive grep 2026-10-16, WRAP_LEDGER item 4).
3. **Terraform destroy** (`enclave/state.ex destroy/1`): reverse-topological
   DELETE walk through the real `Router.call/2` (deepest path-segment count
   first), polls 202 LROs to terminal, verifies 404 per id, then asserts zero
   residue over resource-bearing tables. `@metadata_tables` (listed above)
   are legitimately exempt: LRO history, subscription roots, counters, lock
   tokens, checkpoints, baselines.

Mutations that must be atomic (CAS/etag, cas_delete, sequence assignment) are
serialized through `Smalt.Store`'s GenServer (`compare_and_swap/4`,
`compare_and_swap_delete/3`, `next_seq/3`); SB claim/settle transitions
serialize through `QueueStore`'s own GenServer; EH sequencing through
`EventHubs.Server`.

## See Also

- `lib/smalt/store.ex` — `@tables`, `table_names/0`
- `lib/smalt/enclave/state.ex` — `@metadata_tables`, destroy cascade
- `lib/smalt/data_plane/blob_storage.ex` — FR-6 `drop_account_data/1`
- `docs/jira/v26.10.16/WRAP_LEDGER.md` — D127×FR-6 resolved wording
