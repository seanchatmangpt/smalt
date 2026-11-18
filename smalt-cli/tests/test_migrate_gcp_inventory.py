"""GCP vs AzureRM Terraform resource inventory & classification tests.

Verifies that ``smalt_cli.migrate.terraform`` explicitly detects and
classifies ``google_*`` resources (``GCP_HTTP_EMULATED`` vs
``TYPED_UNSUPPORTED_AZURE_ONLY``) instead of silently skipping them.
"""

from pathlib import Path

import pytest

from smalt_cli.migrate.terraform import (
    GCP_HTTP_EMULATED,
    GCP_HTTP_EMULATED_SERVICES,
    TYPED_UNSUPPORTED_AZURE_ONLY,
    classify_gcp_resource,
    parse_file,
    scan_dir,
)


@pytest.mark.parametrize(
    ("tf_type", "expected_service"),
    [
        ("google_cloud_run_v2_service", "cloud_run_v2"),
        ("google_cloudfunctions2_function", "cloudfunctions2"),
        ("google_storage_bucket", "storage"),
        ("google_pubsub_topic", "pubsub"),
        ("google_kms_crypto_key", "kms"),
        ("google_secret_manager_secret", "secret_manager"),
        ("google_firestore_database", "firestore"),
        ("google_logging_project_sink", "logging"),
        ("google_cloud_tasks_queue", "cloud_tasks"),
    ],
)
def test_classify_gcp_http_emulated_services(tf_type: str, expected_service: str):
    assert expected_service in GCP_HTTP_EMULATED_SERVICES
    assert classify_gcp_resource(tf_type) == (GCP_HTTP_EMULATED, expected_service)


@pytest.mark.parametrize(
    "tf_type",
    [
        "google_compute_instance",
        "google_container_cluster",
        "google_sql_database_instance",
        "google_cloud_run_service",  # v1 is not cloud_run_v2
        "google_bigquery_dataset",
    ],
)
def test_classify_gcp_unmounted_types(tf_type: str):
    assert classify_gcp_resource(tf_type) == (TYPED_UNSUPPORTED_AZURE_ONLY, None)


@pytest.mark.parametrize(
    "tf_type",
    [
        "azurerm_storage_container",
        "azurerm_linux_virtual_machine",
        "aws_s3_bucket",
    ],
)
def test_classify_non_gcp_returns_none(tf_type: str):
    assert classify_gcp_resource(tf_type) is None


def test_parse_file_extracts_and_classifies_all_nine_gcp_services(tmp_path: Path):
    tf = tmp_path / "gcp_emulated.tf"
    tf.write_text(
        '''
resource "google_cloud_run_v2_service" "api" {
  name     = "smalt-api"
  location = "us-central1"
  template {
    containers {
      image = "gcr.io/example/api:latest"
    }
  }
}

resource "google_cloudfunctions2_function" "fn" {
  name     = "smalt-fn"
  location = "us-central1"
}

resource "google_storage_bucket" "assets" {
  name     = "smalt-assets"
  location = "US"
}

resource "google_pubsub_topic" "events" {
  name = "smalt-events"
}

resource "google_kms_crypto_key" "key" {
  name     = "smalt-key"
  key_ring = var.keyring_id
}

resource "google_secret_manager_secret" "db_pass" {
  secret_id = "db-pass"
}

resource "google_firestore_database" "db" {
  name = "(default)"
  type = "FIRESTORE_NATIVE"
}

resource "google_logging_project_sink" "sink" {
  name        = "audit-sink"
  destination = "storage.googleapis.com/${google_storage_bucket.assets.name}"
}

resource "google_cloud_tasks_queue" "jobs" {
  name     = "smalt-jobs"
  location = "us-central1"
}
''',
        encoding="utf-8",
    )

    res = parse_file(tf)
    assert res.errors == []
    assert res.blocks == []
    assert res.unsupported_types == {}
    assert len(res.gcp_resources) == 9

    by_type = {r["tf_type"]: r for r in res.gcp_resources}
    for r in res.gcp_resources:
        assert r["classification"] == GCP_HTTP_EMULATED
        assert r["service"] in GCP_HTTP_EMULATED_SERVICES

    # Attributes and nested blocks are parsed, not skipped
    assert by_type["google_cloud_run_v2_service"]["attributes"]["name"] == "smalt-api"
    assert "template" in by_type["google_cloud_run_v2_service"]["nested_blocks"]
    assert by_type["google_kms_crypto_key"]["attributes"]["key_ring"]["ref_kind"] == "var"
    assert by_type["google_logging_project_sink"]["attributes"]["destination"]["unresolved"] is True


def test_scan_dir_mixed_azurerm_gcp_emulated_and_unmounted(tmp_path: Path):
    (tmp_path / "main.tf").write_text(
        '''
resource "azurerm_storage_container" "blobs" {
  name                 = "blobs"
  storage_account_name = "smaltacct"
}

resource "google_pubsub_topic" "topic" {
  name = "orders"
}

resource "google_compute_instance" "vm" {
  name         = "legacy-vm"
  machine_type = "e2-medium"
}

resource "aws_s3_bucket" "other" {
  bucket = "other-bucket"
}
''',
        encoding="utf-8",
    )

    res = scan_dir(tmp_path)
    assert res.errors == []
    assert res.files_scanned == 1

    # AzureRM supported resource -> blocks
    assert [b.tf_type for b in res.blocks] == ["azurerm_storage_container"]

    # GCP resources -> gcp_resources with explicit classification
    assert len(res.gcp_resources) == 2
    by_type = {r["tf_type"]: r for r in res.gcp_resources}
    assert by_type["google_pubsub_topic"]["classification"] == GCP_HTTP_EMULATED
    assert by_type["google_pubsub_topic"]["service"] == "pubsub"
    assert by_type["google_compute_instance"]["classification"] == TYPED_UNSUPPORTED_AZURE_ONLY
    assert by_type["google_compute_instance"]["service"] is None
    assert by_type["google_compute_instance"]["attributes"]["machine_type"] == "e2-medium"

    # Unmounted google_* and non-Azure/non-GCP types -> unsupported_types
    assert res.unsupported_types == {
        "google_compute_instance": 1,
        "aws_s3_bucket": 1,
    }
