# SM1 receipt

Standing: UNVERIFIED

Cause: Plug 1.20 `put_req_header("host", ...)` raises InvalidHeaderError (20 failures in
test/aws per /tmp/sm_test.log rc=2). Fix: tests append host via `req_headers` directly.
Files: test/aws/{sigv4,sts,secretsmanager,s3,sns}_test.exs. Not re-run (coordinator gates).

## Result (W3-11 parity receipt)

Block-status: UNVERIFIED

- Command: `mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` (cwd /Users/sac/smalt)
- Exit: NOT OBSERVED by this lane (session testimony only: 76 gcp+aws combined, unverified)
- AWS-only `mix test /Users/sac/smalt/test/aws` exit/count: not separately recorded. Coordinator
  runs it and replaces this line with observed exit and count; PASS only on exit 0.
- KD-AWS-01..03 and KD-SQ2 remain OPEN in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md.
