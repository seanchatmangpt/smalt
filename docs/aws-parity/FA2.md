# FA2 SNS test drain QueueUrl

Standing: UNVERIFIED

- Cause: test helper drain/1 passed QueueName; SqsActions.receive_message requires QueueUrl
  (queue_from_params, sqs_actions.ex:545).
- Fix: test/aws/sns_test.exs drain/1 now passes SqsActions.queue_url("localhost", q).
- sns.ex delivery already sends QueueUrl (sns.ex:118); unchanged.
- Gates not run (coordinator owns).

## Result (W3-11 parity receipt)

Block-status: UNVERIFIED

- Command: `mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` (cwd /Users/sac/smalt)
- Exit: NOT OBSERVED by this lane (session testimony only: 76 gcp+aws combined, unverified)
- AWS-only `mix test /Users/sac/smalt/test/aws` exit/count: not separately recorded. Coordinator
  runs it and replaces this line with observed exit and count; PASS only on exit 0.
- KD-AWS-01..03 and KD-SQ2 remain OPEN in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md.
