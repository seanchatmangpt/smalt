# smalt-02 aws parity receipts and sqs sigv4 verify

Standing: UNVERIFIED

## Problem

AWS parity receipts `/Users/sac/smalt/docs/aws-parity/AS1.md`, `AS2.md`, `AS3.md`, `SW6.md` all say
"Standing: UNVERIFIED", authored never compiled. KD-SQ2 (OPEN) records that SQS routes in
`/Users/sac/smalt/lib/smalt/egress/sqs/sqs_routes.ex:25` admit any well-formed SigV4 header without
calling `Smalt.AWS.SigV4.verify/3`. Parity claims therefore lack receipts.

## Acceptance

- Run mix compile with warnings-as-errors, then the `/Users/sac/smalt/test/aws` suite; record output
  in
  each of AS1-AS3 and SW6 and update their Standing from the output.
- Wire `SigV4.verify/3` into the SQS routes; add a test sending a bad signature.
- Expected: bad signature answers SignatureDoesNotMatch; /Users/sac/smalt/test/aws has 0 failures;
  KD-SQ2 closed with the receipt path.

## Falsifier

Revert the verify call in sqs_routes.ex; the new bad-signature test must fail.

## Owned files

/Users/sac/smalt/docs/aws-parity/{AS1,AS2,AS3,SW6}.md,
/Users/sac/smalt/lib/smalt/egress/sqs/sqs_routes.ex,
/Users/sac/smalt/test/aws/sigv4_test.exs, KNOWN_DIVERGENCES.md (KD-SQ2 row only)

## Depends-on

none

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docs/aws-parity/AS1.md : 19 lines
- /Users/sac/smalt/docs/aws-parity/AS2.md : 37 lines
- /Users/sac/smalt/docs/aws-parity/AS3.md : 24 lines
- /Users/sac/smalt/docs/aws-parity/SW6.md : 36 lines
- /Users/sac/smalt/lib/smalt/egress/sqs/sqs_routes.ex : 207 lines
- /Users/sac/smalt/lib/smalt/aws/sigv4.ex : 126 lines
- /Users/sac/smalt/test/aws/sigv4_test.exs : 38 lines
- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines (KD-SQ2 at line 383)
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total

## Result

Standing: UNVERIFIED (no execution observed)

Files changed: /Users/sac/smalt/lib/smalt/egress/sqs/sqs_routes.ex (~+45 LOC, verify wired),
/Users/sac/smalt/test/aws/sigv4_test.exs (+~30, bad/good SQS signature tests),
/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (KD-SQ2 row CLOSED),
/Users/sac/smalt/docs/aws-parity/{AS1,AS2,AS3,SW6}.md (+8 each, Result stubs, UNVERIFIED).

Acceptance (coordinator): in /Users/sac/smalt run compile with --warnings-as-errors, then
the test/aws suite.
Risk: existing SQS courts signing with creds not in :aws_creds now get 403; pass creds opt or set env.
