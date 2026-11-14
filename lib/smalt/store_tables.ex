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

    # binaryPrefix | Smalt.DataPlane.QueueStorage | sweep=retention
    :smalt_q_messages,

    # binaryPrefix | Smalt.DataPlane.QueueStorage | sweep=retention
    :smalt_q_queues,

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
    # integer | Smalt.Monitor.ActivityLog | shadow (owner-managed, never swept)
    :smalt_activity_log,

    # atom | Smalt.Projection.Admission | shadow (owner-managed, never swept)
    :smalt_admission_matrix,

    # binaryPrefix | Smalt.ArmGateway.Router | shadow (owner-managed, never swept)
    :smalt_affidavit_witnesses,

    # tuple | Smalt.Monitor.AppInsights | shadow (owner-managed, never swept)
    :smalt_ai_items,

    # tuple | Smalt.Messaging.AMQP.AtomBridge | shadow (owner-managed, never swept)
    :smalt_amqp_atom_rl,

    # binaryPrefix | Smalt.Aoq.Admission | shadow (owner-managed, never swept)
    :smalt_aoq_admission_ledger,

    # atom | Smalt.Aoq.Admission | shadow (owner-managed, never swept)
    :smalt_aoq_batch_not_list,

    # atom | Smalt.DataPlane.ApimGateway | shadow (owner-managed, never swept)
    :smalt_apim_finch,

    # tuple | Smalt.DataPlane.ApimGateway | shadow (owner-managed, never swept)
    :smalt_apim_rate,

    # tuple | Smalt.Apim | shadow (owner-managed, never swept)
    :smalt_apim_rate_limit,

    # tuple | Smalt.DataPlane.AppconfigRevisions | shadow (owner-managed, never swept)
    :smalt_appconfig_revisions,

    # tuple | Smalt.DataPlane.AppconfigSnapshots | shadow (owner-managed, never swept)
    :smalt_appconfig_snapshots,

    # integer | Smalt.ArmGateway.ActivityLog | shadow (owner-managed, never swept)
    :smalt_arm_activity_log,

    # armId | Smalt.Arm.Deployments | shadow (owner-managed, never swept)
    :smalt_arm_deployments,

    # armId | Smalt.Arm.Dns | shadow (owner-managed, never swept)
    :smalt_arm_dns,

    # tuple | Smalt.Arm.Dns | shadow (owner-managed, never swept)
    :smalt_arm_dns_records,

    # armId | Smalt.Arm.ResourceHealth | shadow (owner-managed, never swept)
    :smalt_arm_health,

    # tuple | Smalt.ArmGateway.ProviderState | shadow (owner-managed, never swept)
    :smalt_arm_provider_state,

    # binaryPrefix | Smalt.Arm.ResourceProviders | shadow (owner-managed, never swept)
    :smalt_arm_providers,

    # tuple | Smalt.ArmGateway.Router | shadow (owner-managed, never swept)
    :smalt_arm_rate,

    # armId | Smalt.Arm.Rbac | shadow (owner-managed, never swept)
    :smalt_arm_rbac_assignments,

    # armId | Smalt.Arm.Rbac | shadow (owner-managed, never swept)
    :smalt_arm_rbac_defs,

    # tuple | Smalt.DataPlane.AzureCache | shadow (owner-managed, never swept)
    :smalt_azure_cache,

    # tuple | Smalt.DataPlane.BlobStorage | shadow (owner-managed, never swept)
    :smalt_blob_blocks,

    # binaryPrefix | Smalt.DataPlane.BlobCors | shadow (owner-managed, never swept)
    :smalt_blob_cors,

    # atom | Smalt.EgressRouter | shadow (owner-managed, never swept)
    :smalt_blob_face,

    # binaryPrefix | Smalt.DataPlane.Blob.Website | shadow (owner-managed, never swept)
    :smalt_blob_service_props,

    # binaryPrefix | Smalt.DataPlane.BlobSoftDelete | shadow (owner-managed, never swept)
    :smalt_blob_soft_delete_props,

    # tuple | Smalt.DataPlane.BlobSoftDelete | shadow (owner-managed, never swept)
    :smalt_blob_soft_deleted,

    # tuple | Smalt.DataPlane.BlobSoftDelete | shadow (owner-managed, never swept)
    :smalt_blob_versions,

    # tuple | Smalt.Messaging.AMQP.CBSRouter | shadow (owner-managed, never swept)
    :smalt_cbs_claims,

    # atom | Smalt.AshExtension.GeneratedPersist | shadow (owner-managed, never swept)
    :smalt_compiled,

    # atom | Smalt.DataPlane.CosmosConsistency | shadow (owner-managed, never swept)
    :smalt_cosmos_consistency,

    # tuple | Smalt.DataPlane.CosmosAuthz | shadow (owner-managed, never swept)
    :smalt_cosmos_permissions,

    # tuple | Smalt.DataPlane.CosmosAuthz | shadow (owner-managed, never swept)
    :smalt_cosmos_resource_tokens,

    # tuple | Smalt.DataPlane.Cosmos | shadow (owner-managed, never swept)
    :smalt_cosmos_ru,

    # tuple | Smalt.DataPlane.CosmosAuthz | shadow (owner-managed, never swept)
    :smalt_cosmos_users,

    # binaryPrefix | Smalt.ArmGateway.CostManagement | shadow (owner-managed, never swept)
    :smalt_cost_usage,

    # tuple | Smalt.ArmGateway.DiagnosticSettings | shadow (owner-managed, never swept)
    :smalt_diag_settings,

    # atom | Smalt.EgressRouter | shadow (owner-managed, never swept)
    :smalt_egress_guard,

    # tuple | Smalt.Messaging.EventHubs | shadow (owner-managed, never swept)
    :smalt_eh_cgs,

    # tuple | Smalt.Messaging.AMQP.Connection | shadow (owner-managed, never swept)
    :smalt_eh_epochs,

    # binaryPrefix | Smalt.Messaging.EhGeoDr | shadow (owner-managed, never swept)
    :smalt_eh_geo_dr,

    # tuple | Smalt.Egress.SchemaRegistryRoutes | shadow (owner-managed, never swept)
    :smalt_eh_schemas,

    # tuple | Smalt.Messaging.EhThrottle | shadow (owner-managed, never swept)
    :smalt_eh_throttle,

    # atom | Smalt.Projection.Admission | shadow (owner-managed, never swept)
    :smalt_event,

    # tuple | Smalt.DataPlane.FileShare | shadow (owner-managed, never swept)
    :smalt_file_shares,

    # tuple | Smalt.Messaging.PartitionLog | shadow (owner-managed, never swept)
    :smalt_kafka_batches,

    # tuple | Smalt.Messaging.Kafka.GroupManager | shadow (owner-managed, never swept)
    :smalt_kafka_group_offsets,

    # binaryPrefix | Smalt.Messaging.Kafka.GroupManager | shadow (owner-managed, never swept)
    :smalt_kafka_groups,

    # tuple | Smalt.Messaging.PartitionLog | shadow (owner-managed, never swept)
    :smalt_kafka_next,

    # binaryPrefix | Smalt.Attestation.Maa | shadow (owner-managed, never swept)
    :smalt_maa_nonces,

    # tuple | Smalt.Egress.MarketplaceRoutes | shadow (owner-managed, never swept)
    :smalt_marketplace_saas,

    # tuple | Smalt.Monitor.MetricAlerts | shadow (owner-managed, never swept)
    :smalt_metric_alerts,

    # tuple | Smalt.Monitor.Metrics | shadow (owner-managed, never swept)
    :smalt_monitor_metrics,

    # tuple | Smalt.Messaging.OffsetJournal | shadow (owner-managed, never swept)
    :smalt_offset_checkpoints,

    # tuple | Smalt.Messaging.OffsetJournal | shadow (owner-managed, never swept)
    :smalt_offset_checkpoints_dets,

    # binaryPrefix | Smalt.Identity.OidcCodeStore | shadow (owner-managed, never swept)
    :smalt_oidc_codes,

    # binaryPrefix | Smalt.Identity.OidcAuthorize | shadow (owner-managed, never swept)
    :smalt_oidc_refresh_tokens,

    # binaryPrefix | Smalt.Policy | shadow (owner-managed, never swept)
    :smalt_policy,

    # tuple | Smalt.Powl2.ChangeFeed | shadow (owner-managed, never swept)
    :smalt_powl2_change_feed_cdc,

    # tuple | Smalt.Powl2.ChangeFeed | shadow (owner-managed, never swept)
    :smalt_powl2_change_feed_docs,

    # binaryPrefix | Smalt.Pplan.Task | shadow (owner-managed, never swept)
    :smalt_pplan_tasks,

    # binaryPrefix | Smalt.ArmGateway.Router | shadow (owner-managed, never swept)
    :smalt_raw_body,

    # binaryPrefix | Smalt.Policy | shadow (owner-managed, never swept)
    :smalt_rbac,

    # tuple | Smalt.DataPlane.ResourceHealth | shadow (owner-managed, never swept)
    :smalt_resource_health,

    # tuple | Smalt.Telemetry | shadow (owner-managed, never swept)
    :smalt_rolling_counters,

    # tuple | Smalt.Identity.SamlSlo | shadow (owner-managed, never swept)
    :smalt_saml_sessions,

    # tuple | Smalt.Auth.SAS | shadow (owner-managed, never swept)
    :smalt_sas_permissions,

    # tuple | Smalt.Amqp.SbAuthRules | shadow (owner-managed, never swept)
    :smalt_sb_auth_rules,

    # tuple | Smalt.Messaging.AMQP.Sweeper | shadow (owner-managed, never swept)
    :smalt_sb_sweeper_lock_tombstones,

    # integer | Smalt.Store | shadow (owner-managed, never swept)
    :smalt_sentinel_forensic,

    # tuple | Smalt.Egress.SignIns | shadow (owner-managed, never swept)
    :smalt_signins_ring,

    # atom | Smalt.AshExtension.GeneratedPersist | shadow (owner-managed, never swept)
    :smalt_store_read,

    # binaryPrefix | Smalt.Sync.Store | shadow (owner-managed, never swept)
    :smalt_sync_frames,

    # tuple | Smalt.DataPlane.TableStorage | shadow (owner-managed, never swept)
    :smalt_tbl_entities,

    # tuple | Smalt.DataPlane.TableStorage | shadow (owner-managed, never swept)
    :smalt_tbl_tables,

    # tuple | Smalt.Egress.ThrottlePlug | shadow (owner-managed, never swept)
    :smalt_throttle_buckets,

    # binaryPrefix | Smalt.DataPlane.Certificates | shadow (owner-managed, never swept)
    :smalt_vault_certificates,

    # binaryPrefix | Smalt.DataPlane.KeyVaultActions | shadow (owner-managed, never swept)
    :smalt_vault_deleted_keys,

    # binaryPrefix | Smalt.DataPlane.KVManagedStorage | shadow (owner-managed, never swept)
    :smalt_vault_managed_storage
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
    :smalt_eh_checkpoints,
    :smalt_event_messages,
    :smalt_ledger_meta,
    :smalt_ledger_transactions,
    :smalt_resources,
    :smalt_sb_rules
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
      :smalt_activity_log => %{
        key_shape: "integer",
        owner_module: "Smalt.Monitor.ActivityLog",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
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
      :smalt_ai_items => %{
        key_shape: "tuple",
        owner_module: "Smalt.Monitor.AppInsights",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_amqp_atom_rl => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.AMQP.AtomBridge",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_aoq_admission_ledger => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Aoq.Admission",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_aoq_batch_not_list => %{
        key_shape: "atom",
        owner_module: "Smalt.Aoq.Admission",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_apim_finch => %{
        key_shape: "atom",
        owner_module: "Smalt.DataPlane.ApimGateway",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_apim_rate => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.ApimGateway",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_apim_rate_limit => %{
        key_shape: "tuple",
        owner_module: "Smalt.Apim",
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
      :smalt_appconfig_revisions => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.AppconfigRevisions",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_appconfig_snapshots => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.AppconfigSnapshots",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_activity_log => %{
        key_shape: "integer",
        owner_module: "Smalt.ArmGateway.ActivityLog",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_arm_deployments => %{
        key_shape: "armId",
        owner_module: "Smalt.Arm.Deployments",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_dns => %{
        key_shape: "armId",
        owner_module: "Smalt.Arm.Dns",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_dns_records => %{
        key_shape: "tuple",
        owner_module: "Smalt.Arm.Dns",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_health => %{
        key_shape: "armId",
        owner_module: "Smalt.Arm.ResourceHealth",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_provider_state => %{
        key_shape: "tuple",
        owner_module: "Smalt.ArmGateway.ProviderState",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_providers => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Arm.ResourceProviders",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_rate => %{
        key_shape: "tuple",
        owner_module: "Smalt.ArmGateway.Router",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_rbac_assignments => %{
        key_shape: "armId",
        owner_module: "Smalt.Arm.Rbac",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_arm_rbac_defs => %{
        key_shape: "armId",
        owner_module: "Smalt.Arm.Rbac",
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
      :smalt_azure_cache => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.AzureCache",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_blob_cors => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.BlobCors",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_blob_face => %{
        key_shape: "atom",
        owner_module: "Smalt.EgressRouter",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_blob_policy => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_blob_service_props => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.Blob.Website",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_blob_snapshots => %{
        key_shape: "armId",
        owner_module: "Smalt.Store",
        sweep_strategy: "cascade",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_blob_soft_delete_props => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.BlobSoftDelete",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_blob_soft_deleted => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.BlobSoftDelete",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_blob_versions => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.BlobSoftDelete",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_cosmos_consistency => %{
        key_shape: "atom",
        owner_module: "Smalt.DataPlane.CosmosConsistency",
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
      :smalt_cosmos_permissions => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.CosmosAuthz",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_cosmos_pk_meta => %{
        key_shape: "tuple",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_cosmos_resource_tokens => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.CosmosAuthz",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_cosmos_ru => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.Cosmos",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_cosmos_users => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.CosmosAuthz",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_cost_usage => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.ArmGateway.CostManagement",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_diag_settings => %{
        key_shape: "tuple",
        owner_module: "Smalt.ArmGateway.DiagnosticSettings",
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
      :smalt_eh_cgs => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.EventHubs",
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
        persisted: true,
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
      :smalt_eh_geo_dr => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Messaging.EhGeoDr",
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
      :smalt_eh_schemas => %{
        key_shape: "tuple",
        owner_module: "Smalt.Egress.SchemaRegistryRoutes",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_eh_throttle => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.EhThrottle",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_file_shares => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.FileShare",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_kafka_batches => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.PartitionLog",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_kafka_group_offsets => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.Kafka.GroupManager",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_kafka_groups => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Messaging.Kafka.GroupManager",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_kafka_next => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.PartitionLog",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_maa_nonces => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Attestation.Maa",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_marketplace_saas => %{
        key_shape: "tuple",
        owner_module: "Smalt.Egress.MarketplaceRoutes",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_metric_alerts => %{
        key_shape: "tuple",
        owner_module: "Smalt.Monitor.MetricAlerts",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_metrics => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Store",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_monitor_metrics => %{
        key_shape: "tuple",
        owner_module: "Smalt.Monitor.Metrics",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_offset_checkpoints => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.OffsetJournal",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_offset_checkpoints_dets => %{
        key_shape: "tuple",
        owner_module: "Smalt.Messaging.OffsetJournal",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_oidc_codes => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Identity.OidcCodeStore",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_oidc_refresh_tokens => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Identity.OidcAuthorize",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_powl2_change_feed_cdc => %{
        key_shape: "tuple",
        owner_module: "Smalt.Powl2.ChangeFeed",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_powl2_change_feed_docs => %{
        key_shape: "tuple",
        owner_module: "Smalt.Powl2.ChangeFeed",
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
      :smalt_q_messages => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.QueueStorage",
        sweep_strategy: "retention",
        metadata_only: false,
        persisted: false,
        ordered_set: true
      },
      :smalt_q_queues => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.QueueStorage",
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
      :smalt_resource_health => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.ResourceHealth",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_saml_sessions => %{
        key_shape: "tuple",
        owner_module: "Smalt.Identity.SamlSlo",
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
      :smalt_sb_auth_rules => %{
        key_shape: "tuple",
        owner_module: "Smalt.Amqp.SbAuthRules",
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
        persisted: true,
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
      :smalt_signins_ring => %{
        key_shape: "tuple",
        owner_module: "Smalt.Egress.SignIns",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_sync_frames => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.Sync.Store",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_tbl_entities => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.TableStorage",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_tbl_tables => %{
        key_shape: "tuple",
        owner_module: "Smalt.DataPlane.TableStorage",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_throttle_buckets => %{
        key_shape: "tuple",
        owner_module: "Smalt.Egress.ThrottlePlug",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
      },
      :smalt_vault_certificates => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.Certificates",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
      :smalt_vault_managed_storage => %{
        key_shape: "binaryPrefix",
        owner_module: "Smalt.DataPlane.KVManagedStorage",
        sweep_strategy: "none",
        metadata_only: false,
        persisted: false,
        ordered_set: false
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
