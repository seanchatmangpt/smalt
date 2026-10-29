# Residual internal tier census (WO-10, reconciled BK-71): the Non-Duplication
# guard.
#
# Pure file-read court over test/internal — no application state, no
# subprocesses, no network. Enforces the tier's composition:
#
#   (a) population fence — exactly the registered files, nothing else
#       (drift in either direction fails loudly);
#   (b) forbidden-token scan — unaudited pacing outside the audited poll
#       helper or a `# SLEEP-CLASS:`-annotated bounded-poll step; raw HTTP
#       clients, test-only conn helpers, JSON decoders, HTTP-status
#       literals co-occurring with assert, and ARM path literals outside
#       a typed per-file exemption (see @exemptions — every row names the
#       rule it lifts and the observed behavior it covers; unregistered
#       hits still fail);
#   (c) observables allowlist — every `Smalt.`-prefixed module reference
#       in the tier must be inside the closed set of modules this tier is
#       allowed to reference.
#
# A gate that cannot exit 1 is the failure: every scan below is written
# so a violation produces a named, typed failure with file+line. A new
# file that lands unregistered trips the population fence before any
# scan exemption can hide it.
defmodule InternalTier.CensusTest do
  use ExUnit.Case, async: true

  @dir __DIR__
  @helper "poll_helper.exs"

  # -- (a) registered population -----------------------------------------------
  # Every file below is registered with its tier class. Classes:
  #   :observer     — residual observer tier, strict rules, no exemptions
  #   :internal     — in-process internal test (test-only conn helpers / local
  #                   JSON reads are ok per typed exemption rows)
  #   :wire         — real loopback wire court (raw clients / sockets / status)
  # Each exemption is typed per rule so a file growing a NEW forbidden
  # behavior still fails the census.
  @registered %{
    "amqp_listener_cap_test.exs" => :observer,
    "armstrong_idiom_court_test.exs" => :wire,
    "ath1_batch_frame_receiver_court_test.exs" => :wire,
    "az2_maa_attestation_court_test.exs" => :internal,
    "az4_mhsm_release_policy_court_test.exs" => :wire,
    "expl3_dataplane_repairs_court_test.exs" => :internal,
    "expl5r1_court_test.exs" => :internal,
    "expl5r2_court_test.exs" => :internal,
    "expl6r1_journal_court_test.exs" => :internal,
    "expl8r_court_test.exs" => :internal,
    "expl9r1_egress_guard_court_test.exs" => :wire,
    "expl9r2_arm_guard_court_test.exs" => :wire,
    "mcpt1_dispatch_court_test.exs" => :internal,
    "kd169r_cred_gate_test.exs" => :wire,
    # EXPL-10/-11 follow-up courts (BK-CENS2 sweep): expl10r2 is an
    # in-process conn-dispatch court over PushRouter/LawCompiler —
    # client-token on the conn helper + JSON decode, status-literal on the
    # dispatch checks. expl11r1 is a real curl-over-loopback wire court —
    # client-token fires on JSON decode/encode calls.
    "expl10r2_court_test.exs" => :internal,
    # expl10r (EXPL10-R lane): F1/F2/F3 high-repair court over the fond runner
    # planner (unprovided_need refusal) + Executor admission/run_op flips.
    # In-process, no wire/JSON/HTTP tokens.
    "expl10r_court_test.exs" => :internal,
    "expl11r1_ledger_range_court_test.exs" => :wire,
    # bkmaap6 (BK-MAAP6 lane): in-process MAA nonce-bounds court over
    # Smalt.Attestation.Maa — real ETS registry, no wire traffic. The
    # status-literal rule fires on the typed 400-refusal tuple checks.
    "bkmaap6_nonce_bounds_court_test.exs" => :internal,
    # bkseqb (BK-SEQB lane): in-process JournalSink seq-base pin court —
    # real JournalSink over a real DETS table, no wire traffic, no tokens.
    "bkseqb_seq_base_court_test.exs" => :internal,
    # bkegs1 (BK-EGS1 lane): real-Bandit crash-fence wire court over
    # template rigs copied verbatim from the subject routers — :wire class;
    # client-token fires on the raw Erlang HTTP client harness.
    "bkegs1_fence_court_test.exs" => :wire,
    # expl11r2: IN-FLIGHT (EXPL11-R2 lane, mid-edit on disk, no receipt yet).
    # Name registered to stop the population-fence re-drift; content scans
    # still apply, so any forbidden token the owning lane adds fails loudly.
    "expl11r2_wps_service_events_court_test.exs" => :internal,
    # expl11r (EXPL11-R lane): F2 positive-delivery leg (real 200 handler)
    # + F4 planes empty-selection typed refusal. In-process, no wire calls.
    "expl11r_court_test.exs" => :internal,
    # expl11r3 (EXPL11-R3 lane): F4 planes real-subprocess boot-refusal court
    # + F5 ledger seg_meta typed-refusal legs over a real JournalSink on
    # disk. In-process + one mix subprocess, no wire calls.
    "expl11r3_court_test.exs" => :internal,
    "bkamqpf_f2a_boundary_court_test.exs" => :wire,
    "eplaw_ephemeral_boot_court_test.exs" => :internal,
    "kd173r_audience_scope_court_test.exs" => :internal,
    "kafka_exp4_court_test.exs" => :wire,
    # store4 (BK-ST4W lane): NO-BOOT disposition pin over the real self-booted
    # app — Erlang store4 family compiled but unwired in production path.
    # Registered by BK-SEAL5 under the compile-freeze SLA (owner landed the
    # file unregistered); disclosed in both lanes' receipts.
    "store4_no_boot_test.exs" => :internal,
    # b4rc (BK-B4RC lane): send-gate court landed unregistered; registered by
    # BK-SEAL6 under the compile-freeze SLA (same class as the BK-SEAL5
    # store4 unblock), disclosed in both lanes' receipts.
    "b4rc_send_gate_court_test.exs" => :internal,
    # bkmon3r (BK-MON3R lane): dead accumulator-fallback join repair court —
    # real telemetry into the attached handler + real HTTP/1.1 over loopback
    # against the self-booted ARM gateway router (:wire class; the 200
    # assertions are on-the-wire status checks). Registered by BK-CENS6
    # closing BK-POWLH3-1 (owner landed the file unregistered).
    "bkmon3r_deadjoin_court_test.exs" => :wire,
    # bkplat-platform-route (BK-PLATFORM-ROUTE lane): platform pseudo-resource
    # metric face routing court — real telemetry into the attached handler +
    # real HTTP/1.1 over loopback against the self-booted ARM gateway router
    # (:wire class). Registered by its owner lane.
    "bkplat_platform_route_court_test.exs" => :wire,
    "kd_blob_court_test.exs" => :wire,
    "kd_conf_court_test.exs" => :wire,
    "wps_exp4_court_test.exs" => :wire,
    "wire_exp4_court_test.exs" => :wire,
    "bkvc_consolidated_court_test.exs" => :wire,
    "bk3_jsonsax_court_test.exs" => :observer,
    "bkcells_ard_cas_gate_test.exs" => :observer,
    "bkcells_data04_resize_probe_test.exs" => :observer,
    "spofb_eh_atom_court_test.exs" => :observer,
    "bk101_g3_seam_probe_test.exs" => :internal,
    # kds3_s4 (KD-S3/KD-S4 lane): in-process secrets version-history court —
    # real Store rows + real KvRoutes dispatch over the Plug test conn;
    # client-token fires on the conn helper + JSON decode, status-literal on
    # the dispatchability assertions.
    "kds3_s4_secret_version_history_test.exs" => :internal,
    "bk14_kd143_sqlfilter_persistence_test.exs" => :wire,
    "bk85_seal_invariant_court_test.exs" => :observer,
    "bk27_kd86_auto_ensure_gate_test.exs" => :observer,
    "certificates_pending_test.exs" => :observer,
    "cosmos_analytical_ttl_test.exs" => :observer,
    "cosmos_kd65_scripts_test.exs" => :observer,
    "deferred_listeners_court_test.exs" => :wire,
    "dets_mirror_recovery_test.exs" => :observer,
    "eh_arm_test.exs" => :observer,
    "eh_geo_dr_test.exs" => :observer,
    "eh_throttle_wiring_test.exs" => :internal,
    "ets_auto_court_test.exs" => :observer,
    "event_grid_backpressure_test.exs" => :observer,
    "event_hubs_consumer_groups_test.exs" => :observer,
    "gld6_sql_row_gate_court.exs" => :wire,
    "impl18_heap_probe_test.exs" => :observer,
    "impl25_selective_drain_test.exs" => :internal,
    "impl6_process_label_test.exs" => :observer,
    "internal_tier_census_test.exs" => :observer,
    "ja15_error_logger_court_test.exs" => :wire,
    "journal_reader_court_test.exs" => :internal,
    "kd115_credit_first_delivery_test.exs" => :observer,
    "kd128_partition_readout_test.exs" => :observer,
    "kd134_requester_delivery_test.exs" => :observer,
    "kafka_wire_test.exs" => :wire,
    "w2_dtdl_converter_court_test.exs" => :observer,
    "webpubsub_test.exs" => :wire,
    "petri_net_test.exs" => :observer,
    "plane_blast_radius_test.exs" => :observer,
    "powl2_andon_court.exs" => :internal,
    "powl2_andon_wire_court.exs" => :wire,
    "powl2_change_feed_test.exs" => :observer,
    "powl2_compiler_test.exs" => :observer,
    "powl2_decomposition_test.exs" => :observer,
    "powl2_executor_test.exs" => :observer,
    "powl2_graph_compat_court.exs" => :observer,
    "powl2_law_compiler_court.exs" => :observer,
    "powl2_law_guard_court.exs" => :observer,
    "powl2_nonseparable_court.exs" => :observer,
    "powl2_primitives_test.exs" => :internal,
    "powl2_projection_test.exs" => :observer,
    "powl2_reticle_test.exs" => :observer,
    "pplan_receipt_engine_test.exs" => :observer,
    "process_iterator_court.exs" => :observer,
    "rg404_concurrent_lifecycle_court.exs" => :wire,
    "scvd_concurrency_courts.exs" => :observer,
    "spof3_affidavit_engine_court_test.exs" => :observer,
    "sql_ingest_wire_court.exs" => :wire,
    "vm_zero_growth_test.exs" => :observer,
    "w3cb_vc_export_court_test.exs" => :wire,
    "wasm_nif_lifecycle_test.exs" => :observer,
    "ws_amqp_relay_test.exs" => :wire,
    # -- v26.10.25 registrations (census reconcile, coordinator): each row
    # names the observed behavior it lifts / the tier class it types.
    # kafka down-conversion court (BK-DOWNCV, v26.10.22 lineage): real TCP
    # wire court over the real listener — :wire, no exemption tokens.
    "kafka_downcv_court_test.exs" => :wire,
    # BK-DLQ3 court: in-process EventGrid GenServer + real BlobStorage WORM
    # machinery + real Store-backed spill, no wire traffic.
    "event_grid_dlq_worm_spill_court_test.exs" => :internal,
    # BK-GRAPHREAP caller-side reap helper for --hang runner doubles
    # (required via Code.require_file, not a test module; kill-by-PID
    # census with fail-closed kill verification).
    "hang_reap.exs" => :observer,
    # KD-S3/S4 versions-list court (V20a/V20b): KvRoutes dispatch over the
    # Plug test conn — client-token on the conn helper + JSON decode,
    # status-literal on the dispatchability assertions (same lifts as the
    # kds3_s4 twin).
    "kdlith_w2_versions_list_test.exs" => :internal,
    # BK-ARM2 STS key-cluster purity: in-process persistent_term/env law
    # court, no wire traffic.
    "sts_key_cluster_purity_test.exs" => :internal,
    # P14 TLS-everywhere court: real additive https listener + real
    # bandit_opts resolution over real sockets — :wire, no exemption tokens.
    "tls_all_planes_court_test.exs" => :wire,
    @helper => :observer
  }

  # Typed per-file rule exemptions (BK-71 reconciliation). A row here lifts
  # exactly one scan rule for exactly one file; each carries the observed
  # behavior that justified it. Anything not exempted still fails.
  @exemptions %{
    "armstrong_idiom_court_test.exs" => [:arm_literal],
    "ath1_batch_frame_receiver_court_test.exs" => [:client_token],
    "az2_maa_attestation_court_test.exs" => [:status_literal],
    # b4rc (BK-B4RC lane, registered by BK-SEAL6 under the compile-freeze SLA):
    # the court asserts raw {status, ct, body} tuples from
    # AtomBridge.handle_request/3 — status literals are the subject under test.
    "b4rc_send_gate_court_test.exs" => [:status_literal],
    "az4_mhsm_release_policy_court_test.exs" => [:client_token],
    "expl3_dataplane_repairs_court_test.exs" => [:status_literal],
    "webpubsub_test.exs" => [:client_token],
    "bk14_kd143_sqlfilter_persistence_test.exs" => [:client_token, :status_literal, :arm_literal],
    "bk101_g3_seam_probe_test.exs" => [:client_token, :status_literal],
    "deferred_listeners_court_test.exs" => [:client_token],
    "eh_throttle_wiring_test.exs" => [:client_token, :status_literal],
    "gld6_sql_row_gate_court.exs" => [:client_token, :status_literal],
    "impl25_selective_drain_test.exs" => [:arm_literal],
    "ja15_error_logger_court_test.exs" => [:status_literal],
    "journal_reader_court_test.exs" => [:client_token],
    "powl2_andon_court.exs" => [:client_token],
    "powl2_andon_wire_court.exs" => [:client_token, :status_literal],
    "powl2_primitives_test.exs" => [:status_literal],
    "rg404_concurrent_lifecycle_court.exs" => [:client_token, :arm_literal],
    "sql_ingest_wire_court.exs" => [:client_token, :status_literal],
    "ws_amqp_relay_test.exs" => [:status_literal],
    # AZ/EXPL-4 wave registrations (BK-70rr census reconcile): each row lifts
    # exactly one rule for exactly one file, with the observed justification.
    "kd_blob_court_test.exs" => [:client_token],
    "kd_conf_court_test.exs" => [:client_token],
    "wps_exp4_court_test.exs" => [:client_token],
    "bkvc_consolidated_court_test.exs" => [:client_token],
    "expl5r1_court_test.exs" => [:status_literal],
    # v26.10.22 registrations (BK-CENS census reconcile): each row names the
    # observed behavior it lifts.
    # kd173r: in-process SasVerifier court on typed refusal tuples
    # ({:error, {401, _}}) — no wire traffic, but the status-literal
    # rule fires, so it is lifted for this file only.
    "kd173r_audience_scope_court_test.exs" => [:status_literal],
    # expl8r: in-process JSON-RPC court over the Plug test conn (real
    # router, real MAA attest face) — no wire traffic, but the client-token
    # rule fires on the conn helper + JSON decode and the status-literal
    # rule fires on the dispatchability assertions.
    "expl8r_court_test.exs" => [:client_token, :status_literal],
    # kds3_s4: in-process secrets version-history court over the Plug test
    # conn — client-token on the conn helper + JSON decode, status-literal
    # on the dispatchability assertions (same lifts as expl8r).
    "kds3_s4_secret_version_history_test.exs" => [:client_token, :status_literal],
    # v26.10.22 registrations round 2 (BK-CENS2 census reconcile): each row
    # names the observed behavior it lifts. NOTE: comment text in this file
    # must avoid the literal tokens the scans match (raw client tokens, ARM
    # path segments, "assert" adjacent to a status number) — the census is
    # part of its own scan.
    # expl9r1: real-loopback egress court — client-token rule fires on the
    # raw Erlang HTTP client; status checks are on the wire (:wire class).
    "expl9r1_egress_guard_court_test.exs" => [:client_token],
    # expl9r2: real-loopback ARM guard court with subscription-scope
    # resourcegroup URLs against real ARM error bodies — client-token fires
    # on the raw Erlang HTTP client, arm_literal on the URL strings.
    "expl9r2_arm_guard_court_test.exs" => [:client_token, :arm_literal],
    # mcpt1: in-process conn-dispatch court over the MCP router —
    # client-token fires on the test conn helper + JSON decode,
    # status-literal on the conn.status dispatchability check.
    "mcpt1_dispatch_court_test.exs" => [:client_token, :status_literal],
    # kd169r: real-loopback credential-gate court — client-token fires on
    # the raw Erlang HTTP client + JSON decode; the 401 refusal check is a
    # string match, registered :wire so the status-literal rule does not
    # apply (BK-CENS typed-exemption pattern).
    "kd169r_cred_gate_test.exs" => [:client_token],
    # expl10r2: in-process conn-dispatch court over PushRouter/LawCompiler —
    # client-token on the conn helper + JSON decode, status-literal on the
    # dispatch checks. expl11r1: real curl-over-loopback wire court —
    # client-token fires on JSON decode/encode calls.
    "expl10r2_court_test.exs" => [:client_token, :status_literal],
    "expl11r1_ledger_range_court_test.exs" => [:client_token],
    # bkmaap6: in-process MAA nonce-bounds court — status-literal fires on
    # the typed 400-refusal tuple checks ({:error, 400, ...} shape matches).
    "bkmaap6_nonce_bounds_court_test.exs" => [:status_literal],
    # bkegs1: real-Bandit crash-fence wire court — client-token fires on the
    # raw Erlang HTTP client harness; status checks are on the wire
    # (:wire class).
    "bkegs1_fence_court_test.exs" => [:client_token],
    # kdlith_w2 (V20a/V20b): in-process secrets versions-list court over the
    # Plug test conn — client-token on the conn helper + JSON decode,
    # status-literal on the dispatchability assertions (same lifts as the
    # kds3_s4 twin).
    "kdlith_w2_versions_list_test.exs" => [:client_token, :status_literal],
    # bkmon3r: wire court over the self-booted ARM gateway — client-token
    # fires on the raw Erlang HTTP client harness + JSON decode of the
    # response body; arm_literal fires on the Azure Monitor metrics REST
    # path the court builds (subscriptions/resourceGroups/providers
    # segments, interpolated); status checks ride the wire (:wire class
    # skips the status-literal rule).
    "bkmon3r_deadjoin_court_test.exs" => [:client_token, :arm_literal],
    # bkplat-platform-route: wire court over the self-booted ARM gateway —
    # client-token fires on the raw Erlang HTTP client harness; arm_literal
    # fires on the platform metric-face REST path the court builds
    # (subscriptions/_smalt_monitor/... literal). Status checks ride the
    # wire (:wire class skips the status-literal rule).
    "bkplat_platform_route_court_test.exs" => [:client_token, :arm_literal]
  }

  # ath1 (wire), w3cb (wire), rg404 (wire) status assertions ride the :wire
  # class: wire courts assert real HTTP status on the wire, so the
  # status-literal rule does not apply to :wire-class files at all.

  # Closed observable set (WO-10 contract, extended BK-71): the modules the
  # internal tier may reference — lib/ surface plus registered test-module
  # self-references.
  @observables MapSet.new([
                 "Smalt.Store",
                 "Smalt.StoreTables",
                 "Smalt.Store.DetsMirror",
                 "Smalt.Planes",
                 "Smalt.Plane.DataSupervisor",
                 "Smalt.Plane.ControlSupervisor",
                 "Smalt.Plane.IntegrationSupervisor",
                 "Smalt.Plane.IdentitySupervisor",
                 "Smalt.AmqpBroker",
                 "Smalt.AmqpBroker.ConnSup",
                 "Smalt.Amqp.QueueStore",
                 # BK-B4RC lane observable (registered by BK-SEAL6 under the SLA):
                 # the management-plane dispatcher the b4 harness PUT lands on.
                 "Smalt.Amqp.AtomBridge",
                 "Smalt.Amqp.CbsRouter",
                 "Smalt.Amqp.FrameCodec",
                 "Smalt.Amqp.Connection",
                 "Smalt.Amqp.SasVerifier",
                 "Smalt.Amqp.ManagementRpc",
                 "Smalt.Messaging.EventGrid",
                 "Smalt.Messaging.EventHubs",
                 "Smalt.Messaging.Kafka",
                 "Smalt.Messaging.EhGeoDr",
                 "Smalt.Messaging.EhThrottle",
                 "Smalt.Arm.EhArm",
                 "Smalt.ArmGateway.LRO.Notifier",
                 "Smalt.ArmGateway.LRO.Sweeper",
                 "Smalt.ArmGateway.Router",
                 "Smalt.DataPlane.Certificates",
                 "Smalt.DataPlane.BlobStorage",
                 "Smalt.DataPlane.BlobSoftDelete",
                 "Smalt.DataPlane.KQL",
                 "Smalt.DataPlane.MHSM",
                 "Smalt.DataPlane.QueueStorage",
                 "Smalt.DataPlane.Cosmos",
                 "Smalt.DataPlane.PartitionKey",
                 "Smalt.DataPlane.AppConfigFeatures",
                 "Smalt.EventGrid.PushRouter",
                 "Smalt.EventGridBackpressureTest",
                 "Smalt.EXPL5R2CourtTest",
                 "Smalt.Test.Internal.CertificatesKd104WitnessTest",
                 "Smalt.Test.Internal.ScvdConcurrencyCourtsTest",
                 "Smalt.Test.Internal.CertificatesPendingTest",
                 "Smalt.Test.Internal.CosmosAnalyticalTtlTest",
                 "Smalt.Test.Internal.POWL2ChangeFeedTest",
                 "Smalt.Test.Internal.Powl2PrimitivesTest",
                 "Smalt.EXPL10R.HighRepairsCourtTest",
                 "Smalt.Test.Internal.Ath1BatchFrameReceiverCourtTest",
                 "Smalt.Test.Internal.W3cbVcExportCourtTest",
                 "Smalt.Test.Internal.DeferredListenersCourtTest",
                 "Smalt.Test.Internal.Rg404ConcurrentLifecycleCourtTest",
                 "Smalt.Test.Internal.Bkmon3rDeadjoinCourtTest",
                 "Smalt.Test.Internal.BkplatPlatformRouteCourtTest",
                 "Smalt.Metrics",
                 "Smalt.Internal.EventHubsConsumerGroupsTest",
                 "Smalt.Internal.Kd128PartitionReadoutTest",
                 "Smalt.Internal.EhThrottleWiringTest",
                 "Smalt.Internal.EtsAutoCourtTest",
                 "Smalt.Internal.Bk14Kd143SqlfilterPersistenceTest",
                 "Smalt.Internal.Bk101G3SeamProbeTest",
                 "Smalt.Internal.KdS3S4SecretVersionHistoryTest",
                 "Smalt.DataPlane.KeyVaultActions",
                 "Smalt.Egress.KvRoutes",
                 # L11 delegator courts (test/internal/*_court.exs): the
                 # per-file w6r fallthrough chain modules the courts mount,
                 # plus the delegator routers those chains dispatch through.
                 "Smalt.Egress.W6rSqlIngestFallthrough",
                 "Smalt.Egress.W6rSqlRowGateFallthrough",
                 "Smalt.Egress.SqlIngestRoutes",
                 "Smalt.Egress.GraphRoutes",
                 "Smalt.Internal.WsAmqpRelayTest",
                 "Smalt.Impl25.SelectiveDrainTest",
                 "Smalt.Impl6.ProcessLabelTest",
                 "Smalt.Security.LedgerWriter",
                 "Smalt.Security.ReceiptSigner",
                 "Smalt.Affidavit",
                 "Smalt.Affidavit.WasmEngine",
                 "Smalt.Affidavit.WasmEngine.Supervisor",
                 "Smalt.Config",
                 "Smalt.TLS",
                 "Smalt.Supervisor",
                 "Smalt.Application",
                 "Smalt.Amqp.Listener",
                 "Smalt.Amqp.Sweeper",
                 "Smalt.Amqp10.Ledger",
                 "Smalt.Amqp10.FrameDecoder",
                 "Smalt.Amqp10.Connection",
                 "Smalt.Internal.BkamqpfF2aBoundaryCourtTest",
                 "Smalt.Internal.KD173RAudienceScopeCourtTest",
                 "Smalt.EplawEphemeralBootCourtTest",
                 "Smalt.EgressRouter",
                 "Smalt.Monitor.Metrics",
                 # BK-PLATFORM-ROUTE: the platform pseudo-resource id embeds the
                 # pseudo-provider namespace string `providers/Smalt.Monitor/
                 # platform` (a wire id, not a module reference) — the court
                 # builds that literal path.
                 "Smalt.Monitor",
                 "Smalt.Telemetry.RollingCounters",
                 "Smalt.ProcessIter",
                 "Smalt.Apim",
                 "Smalt.Ocel",
                 "Smalt.SbRules",
                 "Smalt.Sync.Store",
                 "Smalt.Sync.Frame",
                 "Smalt.Sync.Receipt",
                 "Smalt.RuntimeContracts",
                 "Smalt.GraphLaw.SqlRowGate",
                 "Smalt.Arm.Deployments",
                 "Smalt.Receipt.VcExport",
                 "Smalt.Ja15.SiteLogHandler",
                 "Smalt.Ja15.HostileFormatter",
                 "Smalt.Ja15.ErrorLoggerCourtTest",
                 "Smalt.Ja15.RefusalTelemetryHandler",
                 "Smalt.DataPlane.BlobError",
                 "Smalt.DataPlane.BlobError.send_error",
                 "Smalt.PetriNet",
                 "Smalt.Powl2",
                 "Smalt.Powl2.Net",
                 "Smalt.Powl2.HsmSigner",
                 "Smalt.Powl2.ServiceBusRuleManager",
                 "Smalt.Powl2.ChangeFeed",
                 "Smalt.Powl2.AndonCourtTest",
                 "Smalt.Powl2.DecompositionTest",
                 "Smalt.POWL2.ChangeFeed",
                 "Smalt.POWL2.Executor",
                 "Smalt.POWL2.ExecutorTest",
                 "Smalt.POWL2.LawCompiler",
                 "Smalt.POWL2.LawCompilerCourt",
                 "Smalt.POWL2.LawGuardCourtTest",
                 "Smalt.POWL2.Projection",
                 "Smalt.POWL2.Reticle",
                 "Smalt.POWL2.ReticleTest",
                 "Smalt.POWL2.Reticle.AST",
                 "Smalt.Powl2NonseparableCourtTest",
                 "Smalt.Powl2GatesCourtTest",
                 "Smalt.Gld6SqlRowGateCourtTest",
                 "Smalt.SpofbEhAtomCourtTest",
                 "Smalt.ArmstrongIdiomCourtTest",
                 "Smalt.Plan.ReceiptEngine",
                 "Smalt.PPlan.ReceiptEngine",
                 "Smalt.PPlan.ReceiptEngineTest",
                 "Smalt.Storage.JournalSink",
                 "Smalt.Storage.JournalReader",
                 "Smalt.Storage.JournalReaderCourtTest",
                 "Smalt.SqlIngest",
                 "Smalt.Attestation.Maa",
                 "Smalt.Powl2.Andon",
                 "Smalt.DTDL",
                 "Smalt.DTDL.W2CourtTest",
                 "Smalt.Internal.WebPubSubTest",
                 "Smalt.WebPubSub.Token",
                 "Smalt.WebPubSub.Token.verify",
                 # AZ/EXPL-4 wave registrations (BK-70rr census reconcile):
                 # lib/ surface + the new courts' own test-module references.
                 "Smalt.WebPubSub.Socket",
                 "Smalt.WebPubSub.Socket.handle_in",
                 "Smalt.WebPubSub.leave",
                 "Smalt.Auth.XArrCert",
                 "Smalt.CosmosSql.parse",
                 "Smalt.JsonCompat",
                 "Smalt.JsonCompat.stream",
                 "Smalt.JsonCompat.decode",
                 "Smalt.JsonCompat.normalize_for_court",
                 "Smalt.Internal.BK3.JsonsaxCourtTest",
                 "Smalt.Internal.BkcellsArdCasGateTest",
                 "Smalt.Internal.BkcellsData04ResizeProbeTest",
                 "Smalt.Internal.EXPL5R1CourtTest",
                 "Smalt.Internal.Expl6r1JournalCourtTest",
                 "Smalt.Internal.WireExp4CourtTest",
                 "Smalt.Internal.WpsExp4CourtTest",
                 "Smalt.KdBlobCourtTest",
                 "Smalt.Test.Internal.KdConfCourtTest",
                 "Smalt.Test.Internal.BkvcConsolidatedCourtTest",
                 # BK-CENS2 registrations round 2.
                 "Smalt.Test.Internal.Expl9r1EgressGuardCourtTest",
                 "Smalt.Test.Internal.Expl9r2ArmGuardCourtTest",
                 "Smalt.Internal.Kd169rCredGateTest",
                 "Smalt.Mcp",
                 "Smalt.EventGrid.PushRouterPlug",
                 "Smalt.ConfidentialLedger",
                 "Smalt.Test.Internal.Expl10r2CourtTest",
                 "Smalt.Internal.Expl11R2WpsServiceCourtTest",
                 "Smalt.WebPubSub",
                 "Smalt.EgressRouter",
                 "Smalt.BKEGS1.FenceCourtTest",
                 # v26.10.25 registrations (census reconcile): new-tier module
                 # surfaces landed by the Oct 23-25 wave.
                 "Smalt.EventGridDlqWormSpillCourtTest",
                 "Smalt.Internal.KdLithW2VersionsListTest",
                 "Smalt.StsKeyClusterPurityTest",
                 "Smalt.Auth.StsKey",
                 "Smalt.Test.Internal.TlsAllPlanesCourtTest"
               ])

  # -- (a) population fence ---------------------------------------------------

  test "population fence: test/internal contains exactly the registered files" do
    on_disk = MapSet.new(File.ls!(@dir))
    registered = MapSet.new(Map.keys(@registered))

    assert MapSet.equal?(on_disk, registered),
           "test/internal population drifted: on_disk=#{inspect(MapSet.difference(on_disk, registered))} " <>
             "unregistered=#{inspect(MapSet.difference(registered, on_disk))}"
  end

  # -- (b) forbidden-token scans ------------------------------------------------

  test "no unaudited pacing token outside the audited poll helper" do
    pattern = sleep_pattern()

    violations =
      File.ls!(@dir)
      |> Enum.reject(&(&1 == @helper))
      |> Enum.flat_map(fn name ->
        lns = lines(File.read!(Path.join(@dir, name)))

        lns
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, i} ->
          code = strip_comment(line)

          if Regex.match?(pattern, code) and not sleep_class_annotated?(lns, i) do
            [{name, line}]
          else
            []
          end
        end)
      end)

    assert violations == [], "unaudited pacing outside the helper: #{inspect(violations)}"
  end

  test "no raw HTTP client / test-only conn helpers / JSON decoder tokens" do
    patterns = client_patterns()

    violations =
      scan_lines(fn name, line ->
        not exempted?(name, :client_token) and Enum.any?(patterns, &Regex.match?(&1, line))
      end)

    assert violations == [], "forbidden client tokens: #{inspect(violations)}"
  end

  test "no HTTP status literal co-occurs with assert on the same line" do
    pattern = status_pattern()

    violations =
      scan_lines(fn name, line ->
        class_ok? = Map.get(@registered, name) != :wire

        class_ok? and not exempted?(name, :status_literal) and Regex.match?(pattern, line)
      end)

    assert violations == [], "status-literal asserts: #{inspect(violations)}"
  end

  test "no ARM path literals" do
    violations =
      scan_lines(fn name, line ->
        not exempted?(name, :arm_literal) and
          (Regex.match?(~r/\/subscriptions\//, line) or Regex.match?(~r/\/providers\//, line))
      end)

    assert violations == [], "ARM path literals: #{inspect(violations)}"
  end

  # -- (c) observables allowlist -------------------------------------------------

  test "every Smalt-prefixed module reference is inside the closed allowlist" do
    violations =
      all_files_with_content()
      |> Enum.flat_map(fn {name, content} ->
        # Strip the tier's own helper namespace before scanning.
        content = String.replace(content, "SmaltTest", " ")

        tokens =
          Regex.scan(~r/Smalt\.[A-Za-z0-9_.]+/, content)
          |> Enum.map(fn [tok] -> tok end)
          |> Enum.map(&longest_allowlisted_prefix/1)

        tokens
        |> Enum.reject(&MapSet.member?(@observables, &1))
        |> Enum.uniq()
        |> Enum.map(&{name, &1})
      end)

    assert violations == [], "off-allowlist module references: #{inspect(violations)}"
  end

  # -- helpers -----------------------------------------------------------------

  defp exempted?(name, rule) do
    Map.get(@exemptions, name, []) |> Enum.member?(rule)
  end

  # A sleep is audited when the line itself or one of the 3 preceding lines
  # carries the doctrine's inline typed classification.
  defp sleep_class_annotated?(lns, i) do
    lns
    |> Enum.slice(max(i - 3, 0)..i)
    |> Enum.any?(fn l -> String.contains?(l, "SLEEP-CL" <> "ASS:") end)
  end

  defp strip_comment(line) do
    case String.split(line, ~s(#), parts: 2) do
      [code, _] -> code
      [code] -> code
    end
  end

  # Built from parts so this file's own pattern text never trips the scan
  # (the census file is included in every scan — honest self-scan).
  defp client_patterns do
    [
      Regex.compile!(":" <> "ht" <> "tpc"),
      Regex.compile!("Req" <> "[.]"),
      Regex.compile!("Fin" <> "ch"),
      Regex.compile!("Plug" <> "[.]Te" <> "st"),
      Regex.compile!("Jas" <> "on[.]dec" <> "ode")
    ]
  end

  defp sleep_pattern do
    Regex.compile!("Pro" <> "cess[.]s" <> "leep")
  end

  defp status_pattern do
    Regex.compile!(
      "asse" <> "rt[^\\n]*\\b(200|201|204|400|401|403|404|409|412|500|503)\\b"
    )
  end

  defp scan_lines(pred) do
    for {name, content} <- all_files_with_content(),
        line <- lines(content),
        pred.(name, line),
        do: {name, line}
  end

  defp lines(content) do
    content |> String.split(["\r\n", "\n"])
  end

  defp all_files_with_content do
    @dir
    |> File.ls!()
    |> Enum.sort()
    |> Map.new(fn name ->
      {name, File.read!(Path.join(@dir, name))}
    end)
  end

  defp longest_allowlisted_prefix(token) do
    @observables
    |> Enum.filter(fn allowed -> String.starts_with?(token, allowed) end)
    |> Enum.max_by(&String.length/1, fn -> "" end)
    |> case do
      "" -> token
      allowed -> allowed
    end
  end
end
