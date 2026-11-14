# AWS Parity Receipt v26.11.14

Standing: UNVERIFIED

Subject SHA (HEAD at authoring): d22a1c80f625d970509162a257af0227d58b0fe4
Command: `cd /Users/sac/smalt && mix test test/aws`
Exit code: PENDING (not executed by the authoring lane; coordinator fills from real run)

## Per-service test counts (static `test "` count in file; runtime count PENDING)

| Service | Test file | Static tests | Runtime result |
|---|---|---|---|
| S3 | test/aws/s3_test.exs | 5 | PENDING |
| DynamoDB | test/aws/dynamodb_test.exs | 10 | PENDING |
| STS | test/aws/sts_test.exs | 4 | PENDING |
| KMS | test/aws/kms_test.exs | 5 | PENDING |
| SNS | test/aws/sns_test.exs | 4 | PENDING |
| Secrets Manager | test/aws/secretsmanager_test.exs | 4 | PENDING |
| SigV4 | test/aws/sigv4_test.exs | 4 | PENDING |

## Missing-service refusal

A service whose test file is absent MUST be reported as `MISSING <service>` and the receipt
must not be promoted past UNVERIFIED. Check:

`for s in s3 dynamodb sts kms sns secretsmanager sigv4; do test -f test/aws/${s}_test.exs || { echo "MISSING $s"; exit 1; }; done`

## Promotion

Standing becomes PASS only when the exit code above is 0 with the real `mix test` summary
line pasted here and every row filled from output.
