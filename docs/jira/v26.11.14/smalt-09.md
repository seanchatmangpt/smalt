# smalt-09 AWS and GCP test census receipts

Standing: UNVERIFIED

## Problem

AWS and GCP parity cells carry no run receipts. KD-GCP-05 and KD-AWS-03 in
/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (lines 382, 386) are OPEN with close
condition
"mix test /Users/sac/smalt/test/gcp / /Users/sac/smalt/test/aws green, witnesses recorded". This
session observed
`mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` at 76 passed, but no receipt file
records it.
/Users/sac/smalt/docs/aws-parity/AS1.md and /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md
still say authored,
never run. DynamoDB/SNS/KMS/STS test files exist (/Users/sac/smalt/test/aws/*.exs, 7 files) but
postdate
/Users/sac/smalt/docs/aws-parity/AS1-aws-census.md.

## Acceptance

`cd /Users/sac/smalt && mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws 2>&1 | tail -5`
reports 0 failures and
the count is written to /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-09-census.md with exact
SHA,
command, exit code, and a `Standing:` line. AS1-aws-census.md lists DynamoDB, SNS, KMS,
STS rows. KD-GCP-05 and KD-AWS-03 status flip to CLOSED citing that receipt.

## Falsifier

A test file under /Users/sac/smalt/test/gcp or /Users/sac/smalt/test/aws absent from the receipt
count, or the KD rows
flipped CLOSED with no receipt newer than the /Users/sac/smalt/lib/ files.

## Owned files

/Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-09-census.md,
/Users/sac/smalt/docs/aws-parity/AS1-aws-census.md,
/Users/sac/smalt/docs/aws-parity/AS1.md, /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md,
/Users/sac/smalt/docs/CENSUS.md,
/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (rows 382, 386 only).

## Depends-on

None.

## Size

S

## References (path : LOC)

- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines (rows 382 and 386 only)
- /Users/sac/smalt/docs/aws-parity/AS1-aws-census.md : 17 lines
- /Users/sac/smalt/docs/aws-parity/AS1.md : 19 lines
- /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md : 30 lines
- /Users/sac/smalt/docs/CENSUS.md : 75 lines
- /Users/sac/smalt/test/gcp/ : 9 files, 860 lines total
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-09-census.md : NEW (0 lines, to be created;
  est. LOC: 35; SHA, command, exit code, 16 per-file counts, Standing)

## Result

Standing: UNVERIFIED

Changed: /Users/sac/smalt/docs/aws-parity/AS1-aws-census.md (DynamoDB/SNS/KMS/STS/SecretsMgr rows,
+6 LOC); NEW /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-09-census.md (~25 LOC, run
fields PENDING). KD rows 382/386 left OPEN (no run; falsifier forbids flip). AS1.md,
GCP_WIRE_PARITY.md, CENSUS.md untouched until a run exists.
Coordinator runs: `cd /Users/sac/smalt && mix test test/gcp test/aws 2>&1 | tail -5`, fills receipt, flips KDs.

## Repair
Standing: BLOCKED. Audit MED (census receipt skeleton, SHA/exit/totals PENDING) needs the mix run, not permitted here. Disclosed: disk has 11 GCP test files (ticket says 9); 85 static `test "` lines vs prior 76 passed unreconciled. Rerun the command above and fill smalt-09-census.md.
