# AZ2 Azure Column of 3-Cloud Parity

Standing: UNVERIFIED

Method: read-only inspection of /Users/sac/smalt (no mix/just/git run; no test executed this lane).
HAVE-TESTED = module and live test file exist on disk; pass state is recorded only from the Run result section below (UNVERIFIED until filled).
Machine-readable: AZ2-matrix.json. Matrix: storage, queue_pubsub, document_db, secrets_kms,
identity, serverless, logging all HAVE-TESTED by file presence. 0 GAP cells.

## Caveats

- docs/WIRE_PARITY.md cites test/compliance, test/amqp, test/wire paths; these dirs do not exist
  (retired at 64f6099 per the doc header). Live pins are in test/integration, test/internal,
  test/data_plane, plus gates/*.py and verification/{ts,py}.
- Functions row present in WIRE_PARITY.md (PARTIAL; invocation typed GAP function-runtime-not-emulated).
- Gate receipt: docs/verification/azure-gate-2026-11-14.md (existence loop 0 MISSING; tests PENDING run).
- AZ2 Standing stays UNVERIFIED until that receipt's rows are PASS; derive Standing from the run.
- Service Bus session reply_to is a typed UNSUPPORTED gap (WIRE_PARITY.md:164).

## Pass-state

AZ2-matrix.json carries `pass_state` per cell: UNVERIFIED until the coordinator runs mix test on the
cell tests and rewrites it PASS/FAIL from that output. Row-to-file falsifier: the Functions row pin
test/integration/functions_test.exs must exist; removing it must fail the existence loop in
docs/verification/azure-gate-2026-11-14.md.

## Run result

Command: `mix test test/data_plane test/internal` (cwd /Users/sac/smalt)
Exit: PENDING (coordinator fills)  Count: PENDING (N tests, F failures)
Cells in AZ2-matrix.json move UNVERIFIED -> PASS/FAIL only from this recorded output.

## smalt-10 update

WIRE_PARITY.md cited-path check now 0 MISSING; sdk_coverage.py still exits 1 (40 findings, non-Azure
cap-cells). Receipt: docs/jira/v26.11.14/receipts/smalt-10-azure.md. Cells stay UNVERIFIED.
