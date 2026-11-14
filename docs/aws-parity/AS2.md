# AS2 DynamoDB, KMS, STS receipt

Standing: UNVERIFIED

Lane AS2 authored code and tests only. Per lane contract, mix, just and git were NOT run:
nothing here is compiled or executed. First action for the coordinator is `mix test test/aws`.

## Files (all new)

- `lib/smalt/aws/dynamodb.ex` (`Smalt.AWS.DynamoDB`): engine on `:smalt_cosmos_docs`, keys
  `{:aws_ddb, table, keyterm}` / `{:aws_ddb_meta, table}`. Every write is `Store.insert_new` /
  `compare_and_swap` / `compare_and_swap_delete` with retry (condition re-evaluated on retry).
- `lib/smalt/aws/dynamodb_router.ex` (`Smalt.AWS.DynamoDB.Router`): one Plug for SigV4 service
  `dynamodb` (JSON 1.0), `kms` (JSON 1.1, `TrentService.*`), `sts` (Query/XML).
- `lib/smalt/aws/kms.ex`: AES-256-GCM (versioned blob, rotation keeps old versions decryptable),
  ECC_NIST_P256 ECDSA_SHA_256 sign/verify (RAW/DIGEST), GenerateDataKey, GetPublicKey.
- `lib/smalt/aws/sts.ex`: GetCallerIdentity, AssumeRole (ASIA keys, token, expiry, stored in
  Store; `secret_for/1` feeds SigV4 verify; expired -> refused).
- `test/aws/{dynamodb,kms,sts}_test.exs`: real Store, no mocks, no Process.sleep; includes
  24-way concurrent conditional-create (exactly 1 winner) and 20-way counter increments.

## Reuse

`lib/smalt/aws/sigv4.ex` (AS1) exists and is reused (`parse_auth/1`, `verify/3`, `sign/1`).

## Wiring (coordinator, egress_router.ex)

    plug(Smalt.AWS.DynamoDB.Router, creds: %{"AKIDLOCAL" => "secretLocal"}, identities: %{})

Place alongside the S3 router; it passes through any conn whose SigV4 service is not
dynamodb/kms/sts. No new Store table required (reuses `:smalt_cosmos_docs`, tuple keys).

## UNSUPPORTED (typed errors)

GSI/LSI, Query IndexName, nested-path SET, list_append, streams/TTL, BatchWriteItem/BatchGetItem,
KMS RSA specs/aliases/grants/ReEncrypt/deletion, STS role trust-policy evaluation,
`X-Amz-Security-Token` cross-check.

## Result (W1-07)

Block-status: UNVERIFIED

No build or test executed by this lane. SQS SigV4 verify wired in
lib/smalt/egress/sqs/sqs_routes.ex; KD-SQ2 closed pending run. Coordinator gate: compile with
warnings-as-errors, then the test/aws suite; replace this Standing with observed output.

## Result (W3-11 parity receipt)

Block-status: UNVERIFIED

- Command: `mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` (cwd /Users/sac/smalt)
- Exit: NOT OBSERVED by this lane (session testimony only: 76 gcp+aws combined, unverified)
- AWS-only `mix test /Users/sac/smalt/test/aws` exit/count: not separately recorded. Coordinator
  runs it and replaces this line with observed exit and count; PASS only on exit 0.
- KD-AWS-01..03 and KD-SQ2 remain OPEN in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md.
