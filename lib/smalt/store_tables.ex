# Store Table Registry
# Auto-projected from smalt-substrate-pack ontology via ggen_igniter.sync.
# DO NOT EDIT — regenerate with `mix smalt.gen`.
# Source of truth: ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
# (smalt:StoreTable individuals; queries/store_tables.rq).
#
# This module is the REGISTRY of tables, not accessors: call sites keep
# Store.get(:table, key) — the registry fences coverage, not behavior.
defmodule Smalt.StoreTables do
  @moduledoc """
  Machine-generated registry of every ETS table atom the substrate
  references. Source of truth:
  ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl (smalt:StoreTable).

  Lists:

    * `table_names/0` — the 33 Store-created tables (sweepStrategy != "none"),
      consumed by Smalt.Store as `@tables`
    * `shadow_tables/0` — referenced in lib/, lazily created by owner modules
      (sweepStrategy = "none"; closes the swept-but-unowned bug class,
      :smalt_blob_blocks)
    * `metadata_tables/0` — metadataOnly = true (Smalt.Enclave.State
      destroy-residue exclusions)
    * `persisted_tables/0` — persisted = true (Smalt.Store.DetsMirror
      @default_tables, survives restart)

  Replay identity is fenced by test/store_tables_replay_identity_test.exs;
  coverage of every :smalt_ atom referenced in lib/ is fenced by the same
  test (verify/store-shadow-tables.unbound.rq encodes the ontology side).
  """

  # Canonical ordering: rows are sorted by tableName at render time so the
  # artifact is independent of SPARQL engine row order. Replay identity is
  # fenced by the store-tables replay test.

  @tables [
    # tuple | Smalt.Store | sweep=retention
    :smalt_appconfig,

    # binaryPrefix | Smalt.Store | sweep=metadata
    :smalt_attestation_baseline,

    # armId | Smalt.Store | sweep=cascade
    :smalt_blob_containers,

    # armId | Smalt.Store | sweep=cascade
    :smalt_blob_policy,

    # armId | Smalt.Store | sweep=cascade
    :smalt_blob_snapshots,

    # binaryPrefix | Smalt.Store | sweep=cascade
    :smalt_blobs,

    # tuple | Smalt.Store | sweep=retention
    :smalt_cosmos_docs,

    # tuple | Smalt.Store | sweep=metadata
    :smalt_cosmos_lsn,

    # tuple | Smalt.Store | sweep=retention
    :smalt_cosmos_pk_meta,

    # tuple | Smalt.Store | sweep=retention
    :smalt_eg_topics,

    # tuple | Smalt.Store | sweep=retention
    :smalt_eh_checkpoints,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_eh_partitions,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_event_messages,

    # tuple | Smalt.Store | sweep=metadata
    :smalt_ledger_meta,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_ledger_transactions,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_metrics,

    # armId | Smalt.Store | sweep=metadata
    :smalt_operations,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_purview_edges,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_purview_entities,

    # binaryPrefix | Smalt.Store | sweep=metadata
    :smalt_resource_graph_tokens,

    # armId | Smalt.Store | sweep=cascade
    :smalt_resource_groups,

    # armId | Smalt.Store | sweep=cascade
    :smalt_resources,

    # binaryPrefix | Smalt.Store | sweep=metadata
    :smalt_sb_locks,

    # tuple | Smalt.Store | sweep=retention
    :smalt_sb_messages,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_sb_queues,

    # armId | Smalt.Store | sweep=retention
    :smalt_sb_rules,

    # tuple | Smalt.Store | sweep=metadata
    :smalt_sb_sessions,

    # binaryPrefix | Smalt.Store | sweep=metadata
    :smalt_sb_tokens,

    # binaryPrefix | Smalt.Store | sweep=retention
    :smalt_sentinel_rows,

    # tuple | Smalt.Store | sweep=retention
    :smalt_sentinel_streams,

    # armId | Smalt.Store | sweep=metadata
    :smalt_subscriptions,

    # tuple | Smalt.Store | sweep=retention
    :smalt_vault_keys,

    # tuple | Smalt.Store | sweep=cascade
    :smalt_vault_secrets
  ]

  @shadow_tables [
    # atom | Smalt.Projection.Admission | shadow (owner-managed, never swept)
    :smalt_admission_matrix,

    # binaryPrefix | Smalt.ArmGateway.Router | shadow (owner-managed, never swept)
    :smalt_affidavit_witnesses,

    # tuple | Smalt.ArmGateway.Router | shadow (owner-managed, never swept)
    :smalt_arm_rate,

    # tuple | Smalt.DataPlane.BlobStorage | shadow (owner-managed, never swept)
    :smalt_blob_blocks,

    # tuple | Smalt.Messaging.AMQP.CBSRouter | shadow (owner-managed, never swept)
    :smalt_cbs_claims,

    # atom | Smalt.AshExtension.GeneratedPersist | shadow (owner-managed, never swept)
    :smalt_compiled,

    # tuple | Smalt.DataPlane.Cosmos | shadow (owner-managed, never swept)
    :smalt_cosmos_ru,

    # atom | Smalt.EgressRouter | shadow (owner-managed, never swept)
    :smalt_egress_guard,

    # tuple | Smalt.Messaging.AMQP.Connection | shadow (owner-managed, never swept)
    :smalt_eh_epochs,

    # atom | Smalt.Projection.Admission | shadow (owner-managed, never swept)
    :smalt_event,

    # binaryPrefix | Smalt.Policy | shadow (owner-managed, never swept)
    :smalt_policy,

    # binaryPrefix | Smalt.Pplan.Task | shadow (owner-managed, never swept)
    :smalt_pplan_tasks,

    # binaryPrefix | Smalt.ArmGateway.Router | shadow (owner-managed, never swept)
    :smalt_raw_body,

    # binaryPrefix | Smalt.Policy | shadow (owner-managed, never swept)
    :smalt_rbac,

    # tuple | Smalt.Telemetry | shadow (owner-managed, never swept)
    :smalt_rolling_counters,

    # tuple | Smalt.Auth.SAS | shadow (owner-managed, never swept)
    :smalt_sas_permissions,

    # tuple | Smalt.Messaging.AMQP.Sweeper | shadow (owner-managed, never swept)
    :smalt_sb_sweeper_lock_tombstones,

    # integer | Smalt.Store | shadow (owner-managed, never swept)
    :smalt_sentinel_forensic,

    # atom | Smalt.AshExtension.GeneratedPersist | shadow (owner-managed, never swept)
    :smalt_store_read,

    # binaryPrefix | Smalt.DataPlane.KeyVaultActions | shadow (owner-managed, never swept)
    :smalt_vault_deleted_keys
  ]

  @metadata_tables [
    :smalt_attestation_baseline,
    :smalt_cosmos_lsn,
    :smalt_eh_checkpoints,
    :smalt_ledger_meta,
    :smalt_operations,
    :smalt_resource_graph_tokens,
    :smalt_sb_locks,
    :smalt_sb_sessions,
    :smalt_sb_tokens,
    :smalt_sentinel_streams,
    :smalt_subscriptions
  ]

  @persisted_tables [
    :smalt_blobs,
    :smalt_cosmos_docs,
    :smalt_event_messages,
    :smalt_ledger_meta,
    :smalt_ledger_transactions,
    :smalt_resources
  ]

  @doc """
  Single source of truth for the Store ETS table names. Consumed by
  Smalt.Store (@tables), fenced by the replay-identity test.
  """
  def table_names, do: @tables

  @doc "Referenced in lib/ but created lazily by their owner modules."
  def shadow_tables, do: @shadow_tables

  @doc "Metadata bookkeeping tables (survive the destroy residue check)."
  def metadata_tables, do: @metadata_tables

  @doc "Tables mirrored to :dets by Smalt.Store.DetsMirror (survive restart)."
  def persisted_tables, do: @persisted_tables

  @doc "Owned + shadow: every table atom the substrate references."
  def all_tables, do: table_names() ++ shadow_tables()

  @doc "Per-table registry row: keyShape/owner/sweep/flags."
  def specs do
    %{
      :smalt_admission_matrix => %{
        key_shape: "atom",
        owner_module: "Smalt.Projection.Admission",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_affidavit_witnesses => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.ArmGateway.Router",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_appconfig => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_arm_rate => %{
        key_shape: "tuple",
        owner_module: "Smalt.ArmGateway.Router",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_attestation_baseline => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_blob_blocks => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.BlobStorage",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_blob_containers => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_blob_policy => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_blob_snapshots => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_blobs => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: true,
        ordered_set: true
      },
      :smalt_cbs_claims => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.AMQP.CBSRouter",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_compiled => %{
        key_shape: "atom",
        owner_module: "Smalt.AshExtension.GeneratedPersist",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_cosmos_docs => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: true,
        ordered_set: true
      },
      :smalt_cosmos_lsn => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_cosmos_pk_meta => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_cosmos_ru => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.Cosmos",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_eg_topics => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_egress_guard => %{
        key_shape: "atom",
        owner_module: "Smalt.EgressRouter",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_eh_checkpoints => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_eh_epochs => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.AMQP.Connection",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_eh_partitions => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_event => %{
        key_shape: "atom",
        owner_module: "Smalt.Projection.Admission",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_event_messages => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: true,
        ordered_set: true
      },
      :smalt_ledger_meta => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: true,
        ordered_set: true
      },
      :smalt_ledger_transactions => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: true,
        ordered_set: true
      },
      :smalt_metrics => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_operations => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_policy => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Policy",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_pplan_tasks => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Pplan.Task",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_purview_edges => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_purview_entities => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_raw_body => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.ArmGateway.Router",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_rbac => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Policy",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_resource_graph_tokens => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_resource_groups => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_resources => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: true,
        ordered_set: true
      },
      :smalt_rolling_counters => %{
        key_shape: "tuple",
        owner_module: "Smalt.Telemetry",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_sas_permissions => %{
        key_shape: "tuple",
        owner_module: "Smalt.Auth.SAS",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_sb_locks => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_sb_messages => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_sb_queues => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_sb_rules => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_sb_sessions => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_sb_sweeper_lock_tombstones => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.AMQP.Sweeper",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_sb_tokens => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_sentinel_forensic => %{
        key_shape: "integer",
        owner_module: "Smalt.Store",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_sentinel_rows => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_sentinel_streams => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_store_read => %{
        key_shape: "atom",
        owner_module: "Smalt.AshExtension.GeneratedPersist",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_subscriptions => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "metadata",
        metadata_only: true,
        persisted: false,
        ordered_set: true
      },
      :smalt_vault_deleted_keys => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.KeyVaultActions",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_vault_keys => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_vault_secrets => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      }
    }
  end
end
