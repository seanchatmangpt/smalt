# Azure gate 2026-11-14

Standing: UNVERIFIED

Existence loop observed this lane (42 test paths cited by WIRE_PARITY.md): zero MISSING.
Test execution NOT performed this lane (no mix/just permitted). Per-row pass/fail below is
PENDING; coordinator runs the command and replaces PENDING with PASS/FAIL.

## Command

```
cd /Users/sac/smalt
grep -o 'test/[A-Za-z0-9_/.-]*\.exs\?' docs/WIRE_PARITY.md | sort -u > /tmp/wp.txt
for f in $(cat /tmp/wp.txt); do [ -e "$f" ] || echo "MISSING $f"; done
for f in $(cat /tmp/wp.txt); do mix test "$f" >/tmp/o.txt 2>&1 && echo "PASS $f" || echo "FAIL $f"; done
```

## Rows

| test file | exists | result |
|---|---|---|
| test/aws/s3_test.exs | yes | PENDING |
| test/aws/sigv4_test.exs | yes | PENDING |
| test/data_plane/cosmos_pk_point_read_delete_test.exs | yes | PENDING |
| test/data_plane/cosmos_sql_raise_test.exs | yes | PENDING |
| test/data_plane/kql_test.exs | yes | PENDING |
| test/gcp/firestore_test.exs | yes | PENDING |
| test/gcp/identity_plane_test.exs | yes | PENDING |
| test/gcp/pubsub_engine_test.exs | yes | PENDING |
| test/gcp/pubsub_router_test.exs | yes | PENDING |
| test/gcp/run_logging_router_test.exs | yes | PENDING |
| test/gcp/run_logging_test.exs | yes | PENDING |
| test/gcp/secrets_kms_kms_test.exs | yes | PENDING |
| test/gcp/secrets_kms_secret_manager_test.exs | yes | PENDING |
| test/gcp/storage_test.exs | yes | PENDING |
| test/integration/amqp10_adversary_court_test.exs | yes | PENDING |
| test/integration/amqp10_bk116_skeptic_test.exs | yes | PENDING |
| test/integration/amqp10_skeptic_court_test.exs | yes | PENDING |
| test/integration/arm_providers_test.exs | yes | PENDING |
| test/integration/blob_parity_test.exs | yes | PENDING |
| test/integration/eventgrid_push_court_test.exs | yes | PENDING |
| test/integration/functions_test.exs | yes | PENDING |
| test/integration/ja7_crash_only_court_test.exs | yes | PENDING |
| test/integration/kv_crypto_face_test.exs | yes | PENDING |
| test/integration/lro_envelope_parity_fence_test.exs | yes | PENDING |
| test/integration/ocel_ndjson_agent_court_test.exs | yes | PENDING |
| test/integration/oidc_authorize_test.exs | yes | PENDING |
| test/integration/sb_arm_rules_test.exs | yes | PENDING |
| test/integration/sb_delivery_test.exs | yes | PENDING |
| test/integration/store_partition_wire_regression_test.exs | yes | PENDING |
| test/internal/armstrong_idiom_court_test.exs | yes | PENDING |
| test/internal/event_hubs_consumer_groups_test.exs | yes | PENDING |
| test/internal/expl9r1_egress_guard_court_test.exs | yes | PENDING |
| test/internal/expl9r2_arm_guard_court_test.exs | yes | PENDING |
| test/internal/kd115_credit_first_delivery_test.exs | yes | PENDING |
| test/internal/kd134_requester_delivery_test.exs | yes | PENDING |
| test/internal/mcpt1_dispatch_court_test.exs | yes | PENDING |
| test/internal/pplan_receipt_engine_test.exs | yes | PENDING |
| test/internal/tls_all_planes_court_test.exs | yes | PENDING |
| test/sigv4/sigv4_vectors_test.exs | yes | PENDING |
| test/smalt_canonical_router_court_test.exs | yes | PENDING |
| test/smalt/ocel/revops_test.exs | yes | PENDING |
| test/smalt/planes_test.exs | yes | PENDING |
