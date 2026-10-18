# Receipt: i21b-format-sweep — integration hygiene, format + compile gate

- Date: 2026-10-17
- Lane: integration hygiene (i21b)
- Subject: /Users/sac/smalt @ main working tree (~12 lanes' in-flight edits present)
- Standing: PASS — tree formatted, compile clean, build root reclaimed; 1 pre-existing blocker reported

## Commands and output (final state)

```
$ mix format --check-formatted $(git ls-files 'lib/*.ex' 'test/*.exs' 'test/**/*.ex' \
      'test/**/*.exs' 'lib/**/*.exs' | sort -u)
full-final-exit=0            # every tracked lib/ + test/ file formatted, incl. enclave-testbed

$ MIX_BUILD_ROOT=_build-ft-fmt mix compile --warnings-as-errors --no-deps-check
exit=0
Compiling 133 files (.ex)
Generated smalt app
# zero warnings under --warnings-as-errors (grep -ci warning = 0)

$ rm -rf _build-ft-fmt
removed; ls: _build-ft-fmt: No such file or directory
```

## Sweep history

- **Pass 1**: `--check-formatted` flagged 200 files (formatter config `.formatter.exs`
  unchanged since initial commit 8078b77 — lanes edited without formatting).
  `mix format` applied; 4 files needed a second `mix format` within the pass
  (mid-run lane edits): test/pplan_test.exs, test/data_plane/blob_hardening_test.exs,
  test/auth_enforce_test.exs, lib/smalt/arm_gateway/router.ex.
- **Pass 2 (lane drift during sweep)**: test/compliance/c5_servicebus.exs,
  test/compliance/c7_events.exs, test/amqp/flow_credit_test.exs were re-flagged after
  concurrent lane edits; formatted. During this window the owning lane also repaired
  the syntax error in test/enclave-testbed/enclave_testbed.exs (was: unclosed `try do`
  line 40 / missing `end` at 816:23, unformattable); it now parses and passes
  `--check-formatted`. No action by this lane.
- Final full check: exit 0 (command above).

## Files formatted (pre-format `--check-formatted` flagged list, pass 1, 200 files)

test/pplan_test.exs
test/trust_profile_test.exs
test/wire/egress_wire_test.exs
test/tls_test.exs
test/security/security_hardening_test.exs
test/egress_dispatch_test.exs
test/data_plane/cosmos_test.exs
test/smalt_arm_gateway_test.exs
test/wire_tier_refusal_sweep_test.exs
test/smalt_graphlaw_validator_test.exs
test/zero_drift_serialization_test.exs
test/smalt_services_test.exs
test/wire/arm_wire_test.exs
test/strata_compat_test.exs
test/wire/amqp_wire_test.exs
test/telemetry_test.exs
test/trust_profile_deployment_test.exs
test/auth_enforce_test.exs
test/test_helper.exs
test/spc_drift_test.exs
test/semantic_epoch_test.exs
test/data_plane/blob_hardening_test.exs
test/store_dets_growth_test.exs
test/smalt_native_hcl_ladder_test.exs
test/smalt_ets_composite_identity_test.exs
test/smalt_graphlaw_matrix_test.exs
test/semantic_projection_test.exs
test/smalt_egress_router_test.exs
test/smalt_ets_baseline_identity_test.exs
test/shacl_projection_test.exs
test/mcp_test.exs
test/mcp_wire_test.exs
test/smalt_affidavit_wasm_test.exs
test/lro_test.exs
test/smalt/hw_test.exs
test/sb_children_test.exs
test/runtime_contracts_test.exs
test/security/lens6_fuzz_test.exs
test/route_negative_test.exs
test/sb_rules_test.exs
test/data_plane/audit_planes_test.exs
test/security/lens5_fuzz_test.exs
test/property/frame_codec_property_test.exs
test/security/lens5_crash_class_test.exs
test/ocel_test.exs
test/policy_rbac_test.exs
test/kv_tls_test.exs
test/r32_repairs_test.exs
test/metadata_endpoints_test.exs
test/amqp/fuzz_test.exs
test/eventgrid_topics_arm_test.exs
test/eventgrid_conformance_test.exs
test/ocel_conformance_test.exs
test/ocel_revops_test.exs
test/enclave-testbed/enclave_testbed.exs
test/enclave_state_test.exs
test/kv_secrets_children_test.exs
test/kd78_child_lattice_wire_test.exs
test/enclave_engine_test.exs
test/kd79_blob_apiversion_wire_test.exs
test/data_plane/key_vault_actions_test.exs
test/egress_wiring_test.exs
test/event_stream_test.exs
test/error_codes_doc_test.exs
test/enclave_doctor_severity_test.exs
test/compliance/c4_blob.exs
test/enclave_ocel_test.exs
test/egress_kv_appconfig_test.exs
test/enclave_lifecycle_test.exs
test/dspy_test.exs
test/amqp/event_hubs_test.exs
test/egress_secrets_test.exs
test/e2e/s6_checkpoints/checkpoint_chain.exs
test/data_plane/kql_test.exs
test/compliance/c5_servicebus.exs
test/compliance/c3_cosmos.exs
test/data_plane/cosmos_sql_test.exs
test/defaults_test.exs
test/data_plane/r5_repair_repro_test.exs
test/data_plane/r177d_repro_test.exs
test/data_plane/r133_policy_cas_test.exs
test/compliance/c1_arm.exs
test/corpus/shacl_fuzz.exs
test/data_plane/conditional_headers_test.exs
test/data_plane/blob_service_test.exs
test/amqp/frame_codec_test.exs
test/court_ocel_test.exs
test/compliance/c7_events.exs
test/corpus_test.exs
test/compliance/c6_oauth.exs
test/corpus/vault_enrichment.exs
test/corpus/head_database_account_names.exs
test/corpus/secret_cross_plane_seed.exs
test/amqp/connection_test.exs
lib/smalt/arm_gateway/router.ex
test/corpus/blob_container_reput.exs
test/config_replay_identity_test.exs
test/compliance_test.exs
test/arm/fr5_tf_divergence_closures_test.exs
test/arm_error_corpus_test.exs
test/chaos/port_collision_test.exs
test/ash_extension_test.exs
lib/smalt/egress_router.ex
test/amqp/queue_store_test.exs
test/arm_cascade_teardown_test.exs
test/azapi_actions_test.exs
test/apiversion_matrix_test.exs
test/amqp/flow_credit_test.exs
test/amqp/r129_session_gate_test.exs
test/arm_secret_rotate_test.exs
test/amqp/management_rpc_test.exs
test/amqp/selector_epoch_test.exs
test/amqp/sas_verifier_test.exs
test/amqp/primitive_codec_test.exs
test/amqp/sweeper_test.exs
lib/smalt/trust_profile/trust_profile.ex
lib/smalt/messaging/amqp/connection.ex
test/affidavit_wasm_failclosed_test.exs
test/amqp/lock_manager_test.exs
test/amqp/pyamqp_parity_test.exs
test/admission_projection_test.exs
lib/smalt/tls.ex
test/amqp/broker_facade_test.exs
test/affidavit_ingestion_functor_test.exs
test/amqp/atom_bridge_test.exs
lib/smalt/sb_rules.ex
test/affidavit_seal_test.exs
lib/smalt/store.ex
lib/smalt/trust_profile/deployment.ex
lib/smalt/telemetry.ex
lib/smalt/telemetry/ocel_ndjson.ex
lib/smalt/telemetry/court_ocel.ex
lib/smalt/telemetry/ocel_emitter.ex
lib/smalt/security/ledger_writer.ex
lib/smalt/spc/drift.ex
lib/smalt/semantic/resource.ex
lib/smalt/semantic/ledger_entry.ex
lib/smalt/runtime_contracts/resource_graph_query.ex
lib/smalt/security/attestation.ex
lib/smalt/runtime_contracts/cosmos_header.ex
lib/smalt/runtime_contracts/support.ex
lib/smalt/semantic/evidence.ex
lib/smalt/runtime_contracts.ex
lib/smalt/runtime_contracts/sentinel_ingest.ex
lib/smalt/runtime_contracts/purview_atlas.ex
lib/smalt/runtime_contracts/amqp_dialect.ex
lib/smalt/messaging/amqp/queue_store.ex
lib/smalt/runtime_contracts/arm_envelope.ex
lib/smalt/data_plane/cosmos.ex
lib/smalt/projection/semantic_epoch.ex
lib/smalt/messaging/amqp/management_rpc.ex
lib/smalt/projection/admission.ex
lib/smalt/policy.ex
lib/smalt/pplan/task.ex
lib/smalt/messaging/amqp/frame_codec.ex
lib/smalt/messaging/amqp/primitive_codec.ex
lib/smalt/messaging/event_hubs.ex
lib/smalt/ocel/conformance.ex
lib/smalt/ocel/revops/ocel_trace.ex
lib/smalt/ocel/revops/revops.ex
lib/smalt/ocel/revops/ocel_deviation.ex
lib/smalt/ocel.ex
lib/smalt/ocel/revops/fitness_verdict.ex
lib/smalt/messaging/event_stream.ex
lib/smalt/messaging/amqp/sas_verifier.ex
lib/smalt/graphlaw/validator.ex
lib/smalt/messaging/amqp/lock_manager.ex
lib/smalt/mcp/router.ex
lib/smalt/messaging/amqp/sweeper.ex
lib/smalt/messaging/event_hubs/listener.ex
lib/smalt/messaging/amqp/listener.ex
lib/smalt/messaging/amqp/atom_bridge.ex
lib/smalt/messaging/amqp/cbs_router.ex
lib/smalt/enclave/hcl.ex
lib/smalt/enclave/engine.ex
lib/smalt/messaging/amqp/delivery_encoder.ex
lib/smalt/enclave/doctor.ex
lib/smalt/hw/virtual_serial.ex
lib/smalt/cosmos_sql.ex
lib/smalt/data_plane/kql.ex
lib/smalt/graphlaw/shacl_projection.ex
lib/smalt/hw/signer.ex
lib/smalt/data_plane/key_vault_actions.ex
lib/smalt/fin_ops/calculator.ex
lib/smalt/dspy/remediation.ex
lib/smalt/data_plane/skr.ex
lib/smalt/enclave/remediations.ex
lib/smalt/data_plane/sentinel.ex
lib/smalt/data_plane/purview_atlas.ex
lib/smalt/data_plane/resource_graph.ex
lib/smalt/affidavit/wasm_engine.ex
lib/smalt/auth/bearer.ex
lib/smalt/data_plane/blob_service.ex
lib/smalt/application.ex
lib/smalt/auth/sas.ex
lib/smalt/arm_gateway/provider_matrix.ex
lib/smalt/ash_extension/manual_read.ex
lib/smalt/ash_extension/generated_verify.ex
lib/smalt/auth/body_cache.ex
lib/smalt/ash_extension/generated_persist.ex
lib/smalt/arm_gateway/lro_sweeper.ex
lib/smalt/arm_gateway/lro.ex
lib/mix/tasks/smalt.court_emit.ex
lib/mix/tasks/smalt.doctor.ex
lib/mix/tasks/smalt.destroy.ex
lib/mix/tasks/smalt.apply.ex
lib/mix/tasks/smalt.native_ladder.ex
lib/mix/tasks/smalt.audit_residue.ex
lib/mix/tasks/smalt.enclave_common.ex

## Blocker reported (not fixed — outside formatting scope)

Fresh build-root dep conflict, **pre-existing at HEAD**: mix.exs:120
`{:ex4pm, "~> 26.10.8"}` conflicts with the exact pin in deps/ash_ex4pm/mix.exs:52
`{:ex4pm, "== 26.10.1"}` (ash_ex4pm 26.10.4 hex package). Any fresh MIX_BUILD_ROOT
fails dep resolution:

```
** (Mix) Can't continue due to errors on dependencies
* ex4pm (Hex package)
  does not match the requirement specified
```

mix.lock is unchanged from HEAD on both rows. The shared `_build` masks this because
it never re-resolves deps. Fix belongs to the mix.exs owner lane (align pins or
`override: true`). Zero lib/ compile warnings otherwise.
