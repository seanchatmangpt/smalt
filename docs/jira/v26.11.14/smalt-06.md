# smalt-06 aws parity receipts for s3 dynamodb sts kms sns secretsmanager

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docs/aws-parity/AS1-aws-census.md` states S3 "now closed, unverified" and lists
the
other AWS services as authored without receipts. `/Users/sac/smalt/lib/smalt/aws/` has s3, dynamodb,
sts,
kms, sns, secretsmanager and sigv4, with tests in `/Users/sac/smalt/test/aws/`. No dated gate
receipt
binds those claims to an exact SHA and real output (cf. `/Users/sac/smalt/docs/azure-parity/AZ2.md`:
"no dated gate receipt was found").

## Acceptance

`mix test /Users/sac/smalt/test/aws` exits 0, and
`/Users/sac/smalt/docs/aws-parity/RECEIPT-v26.11.14.md` records the
SHA, command, exit code, and per-service test counts, with a `Standing:` line.

## Falsifier

Delete one service test file; receipt generation must refuse with a named missing
service rather than report a pass.

## Owned files

/Users/sac/smalt/docs/aws-parity/RECEIPT-v26.11.14.md,
/Users/sac/smalt/docs/aws-parity/AS1-aws-census.md

## Depends-on

none

## Result

Standing: UNVERIFIED (no execution observed; hook forbids tests).
Files: /Users/sac/smalt/docs/aws-parity/RECEIPT-v26.11.14.md (new, ~35 LOC),
/Users/sac/smalt/docs/aws-parity/AS1-aws-census.md (+2 LOC).
Acceptance for coordinator: `cd /Users/sac/smalt && mix test test/aws`, then fill exit code and
per-service runtime counts in the receipt; run the missing-service loop in the receipt.

## Size

S

## References (path : LOC)

- /Users/sac/smalt/docs/aws-parity/AS1-aws-census.md : 17 lines
- /Users/sac/smalt/docs/azure-parity/AZ2.md : 17 lines
- /Users/sac/smalt/lib/smalt/aws/ : 11 files, 2064 lines total
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total
- /Users/sac/smalt/docs/aws-parity/RECEIPT-v26.11.14.md : NEW (0 lines, to be created; est. LOC: 40;
  SHA, command, exit code, 7 per-service count rows, Standing)
