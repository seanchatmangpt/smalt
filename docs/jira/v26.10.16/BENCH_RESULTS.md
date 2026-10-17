# Bench Results — v26.10.16

Aggregated from `docs/jira/v26.10.16/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.16/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## b42 — dataplane

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| cosmos_put | 1250 | 509 | 38.62 | 93.35 | 132.10 | 0 |
| cosmos_query | 1250 | 509 | 17.20 | 50.01 | 85.61 | 0 |
| blob_stage_block | 1250 | 509 | 1.16 | 5.22 | 38.08 | 0 |
| blob_commit_block_list | 1250 | 509 | 1.48 | 4.93 | 16.47 | 0 |
| blob_get | 1250 | 509 | 1.06 | 3.93 | 29.91 | 0 |
| kv_put | 1250 | 509 | 0.36 | 1.41 | 14.36 | 0 |
| kv_get | 1250 | 509 | 0.37 | 1.12 | 2.70 | 0 |
| amqp_enqueue | 1250 | 509 | 0.07 | 0.14 | 0.17 | 0 |
| amqp_dequeue_complete_batch | 1250 | 3246 | 0.28 | 0.66 | 0.72 | 0 |
## b7 — store-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| put | 120000 | 1006610 | 0.00 | 0.00 | 0.00 | 0 |
| get | 120000 | 1694796 | 0.00 | 0.00 | 0.00 | 0 |
| compare_and_swap | 120000 | 263479 | 0.00 | 0.00 | 0.00 | 0 |
| concurrent_put_get_32p | 512000 | 11945034 | 0.00 | 0.00 | 0.00 | 0 |
| list_prefix_10k | 10000 | 1539172 | 0.00 | 0.00 | 0.00 | 0 |
## c10 — affidavit-seal

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| admit_and_seal | 100 | 77 | 11.27 | 26.49 | 32.67 | 0 |
## c11 — lifecycle

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| preflight: ports 39310-39315 free | 1 | 2 | 447.00 | 447.00 | 447.00 | 0 |
| substrate tls snapshot + trust shim | 1 | 0 | 2666.00 | 2666.00 | 2666.00 | 0 |
| substrate up: ARM 39310 | 1 | 0 | 2716.00 | 2716.00 | 2716.00 | 0 |
| substrate up: TLS twin 39311 | 1 | 2 | 540.00 | 540.00 | 540.00 | 0 |
| provider mirror | 1 | 2 | 463.00 | 463.00 | 463.00 | 0 |
| provider wrap (ok) | 1 | 1 | 994.00 | 994.00 | 994.00 | 0 |
| tf plan (2 to add) | 1 | 0 | 3557.00 | 3557.00 | 3557.00 | 0 |
| tf apply | 1 | 0 | 141142.00 | 141142.00 | 141142.00 | 0 |
| ryw blob put/get | 1 | 8 | 125.00 | 125.00 | 125.00 | 0 |
| ryw secret put/get | 1 | 2 | 506.00 | 506.00 | 506.00 | 0 |
| ryw cosmos doc put/query | 1 | 2 | 548.00 | 548.00 | 548.00 | 0 |
| tf destroy | 1 | 0 | 21431.00 | 21431.00 | 21431.00 | 0 |
| residue audit (GET=0 + plan empty) | 1 | 2 | 522.00 | 522.00 | 522.00 | 0 |
## c9 — arm


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |

## c9 — blob


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |

## c9 — cosmos


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |

## c9 — eh


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |

## c9 — enclave-loop


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| meta | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |

## c9 — provision


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |

## c9 — secrets


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |

## e1 — arm


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |
| arm_assert | SKIP-LOUD | 0 | 0 | provisioned=false — tf apply did not succeed |

## e1 — blob


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| blob | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |

## e1 — cosmos


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| cosmos | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |

## e1 — eh


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |
| eh_wire_send | SKIP-LOUD | 0 | 0 | no EventHub namespace/hub provisioned by fixture (ARM list empty) |

## e1 — enclave-loop


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |
| meta | PASS | 0 | 0 |  |
| tf_init | PASS | 0 | 0 |  |
| tf_plan | PASS | 0 | 0 |  |

## e1 — provision


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1: by multiple users at the same time. Please resolve the issue above and try \| again. For most commands, you can disable locking with the "-lock=false" \| flag, bu |
| tf_apply | FAIL | 0 | 1 | exit 1:   on main.tf line 14, in resource "azurerm_storage_account" "smalt_fixture": \|   14: resource "azurerm_storage_account" "smalt_fixture" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_apply | SKIP-LOUD | 0 | 0 | substrate down — tf_apply on localhost:39370 refused (exit 1) |
| tf_apply | SKIP-LOUD | 0 | 0 | substrate down — tf_apply on localhost:39370 refused (exit 1) |
| tf_apply | SKIP-LOUD | 0 | 0 | substrate down — tf_apply on localhost:39370 refused (exit 1) |
| tf_apply | SKIP-LOUD | 0 | 0 | substrate down — tf_apply on localhost:39370 refused (exit 1) |
| tf_apply | SKIP-LOUD | 0 | 0 | substrate down — tf_apply on localhost:39370 refused (exit 1) |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_init | SKIP-LOUD | 0 | 0 | registry.terraform.io unreachable (exit 1) |
| tf_init | SKIP-LOUD | 0 | 0 | registry.terraform.io unreachable (exit 1) |
| tf_init | SKIP-LOUD | 0 | 0 | registry.terraform.io unreachable (exit 1) |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_plan | FAIL | 0 | 1 | exit 1:   on versions.tf line 16, in provider "azurerm": \|   16: provider "azurerm" { \|  \|  |
| tf_apply | FAIL | 0 | 1 | exit 1:   on main.tf line 14, in resource "azurerm_storage_account" "smalt_fixture": \|   14: resource "azurerm_storage_account" "smalt_fixture" { \|  \|  |
| tf_apply | FAIL | 0 | 1 | exit 1:   on main.tf line 14, in resource "azurerm_storage_account" "smalt_fixture": \|   14: resource "azurerm_storage_account" "smalt_fixture" { \|  \|  |

## e1 — secrets


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |
| secrets | SKIP-LOUD | 0 | 0 | provisioned=false — ARM assert did not pass |

## lc1 — cloud-chain-blob-journal

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop6 | 200 | 2387 | 0.42 | 0.57 | 0.78 | 0 |
## lc1 — cloud-chain-cosmos-cas

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop3 | 200 | 1167 | 0.86 | 1.06 | 1.41 | 0 |
## lc1 — cloud-chain-e2e

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| cycle | 200 | 176 | 5.67 | 7.76 | 8.54 | 0 |
## lc1 — cloud-chain-eventhubs

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop5 | 200 | 3080 | 0.33 | 0.42 | 0.54 | 0 |
## lc1 — cloud-chain-kv-sign

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop4 | 200 | 645 | 1.55 | 1.82 | 2.06 | 0 |
## lc1 — cloud-chain-next-ingest

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop2 | 200 | 1238 | 0.81 | 1.20 | 1.62 | 0 |
## lc1 — cloud-chain-resource-graph

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop7 | 200 | 2426 | 0.41 | 0.59 | 0.86 | 0 |
## lc1 — cloud-chain-sentinel-ryw

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop8 | 200 | 1163 | 0.86 | 1.07 | 1.20 | 0 |
## lc1 — cloud-chain-sts

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop1 | 200 | 2240 | 0.45 | 0.60 | 0.94 | 0 |
## Non-op records

- `bench/wave-telemetry-run2.jsonl`: wave-telemetry (fleet run telemetry, EXCLUDED from bench aggregation) — 22 record(s), see file for full run data.
- `bench/wave-telemetry.jsonl`: wave-telemetry (fleet run telemetry, EXCLUDED from bench aggregation) — 11 record(s), see file for full run data.
- `a1-change-feed.jsonl`: 2 non-op record(s) (baseline, stall) — see file for full run data.
- `lifecycle-8hop.jsonl`: 2 non-op record(s) (cost-ledger-1M, kd-absent) — see file for full run data.

---
End of generated bench report.
