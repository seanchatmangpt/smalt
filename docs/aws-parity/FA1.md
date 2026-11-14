# FA1 DynamoDB if_not_exists arithmetic

Standing: UNVERIFIED

- (a) Fixed in lib/smalt/aws/dynamodb.ex: SET RHS parsed by eval_rhs/eval_term/split_arith;
  if_not_exists resolves to fallback inside `+`/`-` expressions.
- (b) Counter 400 attributed to CAS retry exhaustion (@retries 8 vs 20 contenders); raised to 256.
- Test added: test/aws/dynamodb_test.exs (if_not_exists inside arithmetic).
- Not run (lane forbids mix); coordinator gates.

## Result (W3-11 parity receipt)

Block-status: UNVERIFIED

- Command: `mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` (cwd /Users/sac/smalt)
- Exit: NOT OBSERVED by this lane (session testimony only: 76 gcp+aws combined, unverified)
- AWS-only `mix test /Users/sac/smalt/test/aws` exit/count: not separately recorded. Coordinator
  runs it and replaces this line with observed exit and count; PASS only on exit 0.
- KD-AWS-01..03 and KD-SQ2 remain OPEN in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md.
