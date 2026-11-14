# GCP Green Run

Standing: UNVERIFIED

NOT A RECEIPT: no execution observed; SHA and output are unfilled (BLOCKED until the
coordinator records a real run). Do not cite or commit as evidence.

## Header

- SHA: UNRECORDED
- Command: `cd /Users/sac/smalt && mix test test/gcp`

## Output

UNRECORDED

## Cell to test-file map (flip to PASS only on 0 failures for that file)

| Cell (GCP_WIRE_PARITY.md) | Test file | Result |
| :--- | :--- | :--- |
| GS1 Cloud Storage core | test/gcp/storage_test.exs | UNVERIFIED |
| GS2 Pub/Sub core | test/gcp/pubsub_engine_test.exs, pubsub_router_test.exs | UNVERIFIED |
| GS3 Firestore core | test/gcp/firestore_test.exs | UNVERIFIED |
| GS4 Secret Manager | test/gcp/secrets_kms_secret_manager_test.exs | UNVERIFIED |
| GS4 Cloud KMS | test/gcp/secrets_kms_kms_test.exs | UNVERIFIED |
| GS5 Identity/IAM | test/gcp/identity_plane_test.exs | UNVERIFIED |
| GS6 Cloud Run v2 services | test/gcp/run_logging_router_test.exs | UNVERIFIED |
| GS6 Cloud Logging | test/gcp/run_logging_test.exs | UNVERIFIED |

## Falsifier

Break one assertion in test/gcp/storage_test.exs; the run must fail and the GS1 core cell
must revert to UNVERIFIED/FAIL.

## See Also

GCP_WIRE_PARITY.md, ../jira/v26.10.14/KNOWN_DIVERGENCES.md (KD-GCP-05)
