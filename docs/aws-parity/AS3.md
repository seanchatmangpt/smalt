# AS3 Receipt

Standing: UNVERIFIED

Authored, never compiled or run (lane forbade mix/just/git). No overlap with AS1 (S3/SigV4) or
AS2 (dynamodb/kms present in lib/smalt/aws); SQS reused, not rewritten.

Files (new only): lib/smalt/aws/{sns,sns_router,secretsmanager,secretsmanager_router}.ex,
test/aws/{sns_test,secretsmanager_test}.exs.

SNS: topics, Subscribe (protocol sqs only, ARN endpoint, idempotent per topic+endpoint),
Publish fan-out via SqsActions.send_message, RawMessageDelivery, FilterPolicy subset
(exact, prefix, anything-but, exists; attribute scope), List*/Get/SetSubscriptionAttributes.
SecretsManager: Create/Put/Get/Describe/Delete(soft+force)/Restore/ListSecrets, stages
AWSCURRENT/AWSPREVIOUS, GetSecretValue by VersionId/VersionStage.

Wiring (coordinator): application.ex children
`{Smalt.AWS.SNS, name: Smalt.AWS.SNS.Default}`, `{Smalt.AWS.SecretsManager, name: Smalt.AWS.SecretsManager.Default}`;
egress_router.ex (before SQS plug):
`plug(Smalt.AWS.SNS.Router, server: Smalt.AWS.SNS.Default, creds: ...)` and
`plug(Smalt.AWS.SecretsManager.Router, server: Smalt.AWS.SecretsManager.Default, creds: ...)`.
Risks: tests assume Smalt.Amqp.QueueStore runs under the app in test env; SNS Subscribe attrs use
SqsQuery.entries_all; MessageAttributes DataType other than String unsupported in filters.
Run: `mix test test/aws/sns_test.exs test/aws/secretsmanager_test.exs`.

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
