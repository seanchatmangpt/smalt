# AS1 Receipt

Standing: UNVERIFIED

Authored, never compiled or run (lane forbade mix/just/git). SQS already existed
(lib/smalt/egress/sqs/*), so no duplicate SQS written; census in AS1-aws-census.md.

Files (new only):
- lib/smalt/aws/sigv4.ex (sign/verify, S3 single-encoding, constant-time compare)
- lib/smalt/aws/s3.ex (pure core + Server Agent: buckets, objects, If-Match/If-None-Match,
  ListObjectsV2, multipart)
- lib/smalt/aws/s3_router.ex (path-style Plug, SigV4-gated, claims service=s3 only)
- test/aws/sigv4_test.exs (includes AWS docs GET-object vector), test/aws/s3_test.exs

Wiring (coordinator): in lib/smalt/egress_router.ex before the SQS plug add
`Smalt.AWS.S3.Router.call(conn, server: Smalt.AWS.S3.Default, creds: &lookup/1)`; start
`{Smalt.AWS.S3.Server, name: Smalt.AWS.S3.Default}` in application.ex. Follow-ups: SQS sig
verify via Smalt.AWS.SigV4.verify/3 (closes KD-SQ2); SQS DLQ redrive behavior untested here.
Run: `mix test test/aws`.

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
