# smalt-10 Azure test directory and parity receipts

Standing: UNVERIFIED

## Problem

/Users/sac/smalt/docs/azure-parity/AZ2.md marks all seven Azure cells HAVE-TESTED by file presence
only
and states pass state was not re-run. It also notes that /Users/sac/smalt/docs/WIRE_PARITY.md cites
/Users/sac/smalt/test/compliance, /Users/sac/smalt/test/amqp, /Users/sac/smalt/test/wire paths that
do not exist. There is no /Users/sac/smalt/test/azure
directory; /Users/sac/smalt/lib/smalt/azure holds only kv_certificates.ex and log_analytics.ex, so
most
Azure evidence lives under /Users/sac/smalt/test/integration and /Users/sac/smalt/test/courts. The
Azure parity claims
(/Users/sac/smalt/docs/azure-parity/AZ2-matrix.json) lack run receipts.

## Acceptance

`cd /Users/sac/smalt && python3 /Users/sac/smalt/scripts/sdk_coverage.py` exits 0 with every Azure
cell
pass, registered divergence, or loud MISSING, and each cited test path in
/Users/sac/smalt/docs/WIRE_PARITY.md resolves: `grep -o 'test/[A-Za-z0-9_/.-]*'
/Users/sac/smalt/docs/WIRE_PARITY.md |
sort -u | while read p; do ls $p >/dev/null || echo MISSING $p; done` prints nothing.
A receipt /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-10-azure.md records the run.

## Falsifier

A path in WIRE_PARITY.md that does not exist on disk, or an AZ2-matrix.json cell marked
HAVE-TESTED whose test file was not executed in the receipt.

## Owned files

/Users/sac/smalt/docs/azure-parity/AZ2.md, /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json,
/Users/sac/smalt/docs/WIRE_PARITY.md (Azure
rows and stale paths), /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-10-azure.md.

## Depends-on

smalt-09 (shared receipt format)

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docs/azure-parity/AZ2.md : 17 lines
- /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json : 9 lines
- /Users/sac/smalt/docs/WIRE_PARITY.md : 296 lines
- /Users/sac/smalt/scripts/sdk_coverage.py : 875 lines
- /Users/sac/smalt/lib/smalt/azure/ : 2 files, 170 lines total
- /Users/sac/smalt/test/integration/ : 165 files, 42401 lines total
- /Users/sac/smalt/test/courts/ : 19 files, 4382 lines total
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-10-azure.md : NEW (0 lines, to be created;
  est. LOC: 40; SHA, sdk_coverage exit code, Azure cell table, path-check output)

## Result

Standing: PARTIAL. Path-check half met (0 MISSING, executed); sdk_coverage.py exit 1 (40 findings, pre-existing cap-cell ground FAIL, not in owned files).
Files: /Users/sac/smalt/docs/WIRE_PARITY.md (path edits), /Users/sac/smalt/docs/azure-parity/AZ2.md (+4 LOC), /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-10-azure.md (new, ~12 LOC).
Acceptance: cd /Users/sac/smalt && python3 scripts/sdk_coverage.py; grep -o 'test/[A-Za-z0-9_/.-]*' docs/WIRE_PARITY.md | sort -u | while read p; do ls $p >/dev/null || echo MISSING $p; done
