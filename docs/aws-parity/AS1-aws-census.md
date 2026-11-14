# AS1 AWS Census

Standing: UNVERIFIED

Census of AWS surfaces in `/Users/sac/smalt/lib` (grep-derived, not executed this lane).

| Service | State | Locus |
|---|---|---|
| SQS | PRESENT: query + JSON(1.0) faces, visibility, RedrivePolicy attr, MD5; SigV4 shape-only (KD-SQ2) | lib/smalt/egress/sqs/* |
| Kinesis | PRESENT, SigV4 re-sign verify when pinned | lib/smalt/egress/KinesisRoutes.ex, test/sigv4 |
| S3 | ABSENT before AS1 | now lib/smalt/aws/s3*.ex |
| DynamoDB | PRESENT (authored, unrun): router + core | lib/smalt/aws/dynamodb.ex, dynamodb_router.ex; test/aws/dynamodb_test.exs (10 tests) |
| SNS | PRESENT (authored, unrun) | lib/smalt/aws/sns.ex, sns_router.ex; test/aws/sns_test.exs (4) |
| KMS | PRESENT (authored, unrun) | lib/smalt/aws/kms.ex; test/aws/kms_test.exs (5) |
| STS | PRESENT (authored, unrun) | lib/smalt/aws/sts.ex; test/aws/sts_test.exs (4) |
| Secrets Manager | PRESENT (authored, unrun) | lib/smalt/aws/secretsmanager*.ex; test/aws/secretsmanager_test.exs (4) |
| Lambda, CloudWatch | ABSENT (grep: no hits) | - |
| SigV4 verifier | Kinesis-private only | now lib/smalt/aws/sigv4.ex (shared) |

GCP slice (lib/smalt/gcp): storage, firestore, pubsub, kms, secret_manager, iam, identity,
logging, cloud_run. AWS parity gaps vs GCP: S3 (test file present, unverified; no per-router test rows in receipt), KMS, Secrets Manager,
DynamoDB/Firestore analog, STS/IAM analog, SNS/Pub-Sub analog, CloudWatch/Logging analog.

Receipt: `RECEIPT-v26.11.14.md` (UNVERIFIED: no test run observed; coordinator records `mix test test/aws`).
