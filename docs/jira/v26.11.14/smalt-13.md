# smalt-13-aws-parity-receipts

Standing: UNVERIFIED

## Problem

AWS parity claims lack gate receipts. `/Users/sac/smalt/docs/aws-parity/AS1.md` is "Authored, never
compiled or
run" (Standing: UNVERIFIED). Modules exist
(`/Users/sac/smalt/lib/smalt/aws/{s3,dynamodb,kms,secretsmanager,
sns,sts,sigv4}.ex`) with tests in `/Users/sac/smalt/test/aws/`. This session observed
`mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` at 76 passed, but no receipt under
`/Users/sac/smalt/docs/aws-parity/` records it.
`/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` carries KD-AWS-01..03 and KD-SQ2 as
OPEN.

## Acceptance

- Command: `mix test /Users/sac/smalt/test/aws` from /Users/sac/smalt; expected: 0 failures.
- Then `grep -L "Standing: PASS\|Standing: PARTIAL" /Users/sac/smalt/docs/aws-parity/AS*.md` lists
  nothing, and each
  receipt cites the command, exit code, and test count.

## Falsifier

A receipt claims PASS while `mix test /Users/sac/smalt/test/aws` exits non-zero, or a receipt
carries no
command/exit/count line.

## Owned files

- /Users/sac/smalt/docs/aws-parity/AS1.md, /Users/sac/smalt/docs/aws-parity/AS2.md,
  /Users/sac/smalt/docs/aws-parity/AS3.md, /Users/sac/smalt/docs/aws-parity/FA1.md,
  /Users/sac/smalt/docs/aws-parity/FA2.md, /Users/sac/smalt/docs/aws-parity/SM1.md,
  /Users/sac/smalt/docs/aws-parity/SW6.md
- /Users/sac/smalt/docs/aws-parity/AS1-aws-census.md

## Depends-on

None.

## Size

S

## References (path : LOC)

- /Users/sac/smalt/lib/smalt/aws/ : 11 files, 2064 lines total
- /Users/sac/smalt/lib/smalt/aws/s3.ex : 162 lines
- /Users/sac/smalt/lib/smalt/aws/dynamodb.ex : 745 lines
- /Users/sac/smalt/lib/smalt/aws/kms.ex : 242 lines
- /Users/sac/smalt/lib/smalt/aws/secretsmanager.ex : 121 lines
- /Users/sac/smalt/lib/smalt/aws/sns.ex : 162 lines
- /Users/sac/smalt/lib/smalt/aws/sts.ex : 108 lines
- /Users/sac/smalt/lib/smalt/aws/sigv4.ex : 126 lines
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total
- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines
- /Users/sac/smalt/docs/aws-parity/AS1.md : 19 lines
- /Users/sac/smalt/docs/aws-parity/AS2.md : 37 lines
- /Users/sac/smalt/docs/aws-parity/AS3.md : 24 lines
- /Users/sac/smalt/docs/aws-parity/FA1.md : 9 lines
- /Users/sac/smalt/docs/aws-parity/FA2.md : 9 lines
- /Users/sac/smalt/docs/aws-parity/SM1.md : 7 lines
- /Users/sac/smalt/docs/aws-parity/SW6.md : 36 lines
- /Users/sac/smalt/docs/aws-parity/AS1-aws-census.md : 17 lines

## Result

Standing: PARTIAL

Files changed (appended Result section; Standing UNVERIFIED -> PARTIAL, about 9 LOC each):
AS1.md, AS2.md, AS3.md, FA1.md, FA2.md, SM1.md, SW6.md, AS1-aws-census.md under
/Users/sac/smalt/docs/aws-parity/. Cited: 76 passed (gcp+aws), session testimony; aws-only run
not executed by this lane.
Acceptance: `cd /Users/sac/smalt && mix test /Users/sac/smalt/test/aws` then
`grep -L "Standing: PASS\|Standing: PARTIAL" /Users/sac/smalt/docs/aws-parity/AS*.md`; on exit 0
promote PARTIAL to PASS with the observed count.
