# smalt-10 Azure parity receipt

Standing: PARTIAL

- Subject: /Users/sac/smalt at d22a1c80f625d970509162a257af0227d58b0fe4 (working tree edits to docs/WIRE_PARITY.md)
- Path check (executed): grep/ls loop over cited test/ paths in docs/WIRE_PARITY.md prints nothing (0 MISSING). Before: 9 missing (test/amqp, test/compliance, test/wire, test/integration/amqp10_ glob, test/security/lens6_ glob, 3x test/sdk-smoke).
- Remap: amqp10 globs -> amqp10_adversary/skeptic court tests; lens6 -> test/integration/ja7_crash_only_court_test.exs; census -> verification/ts/census.test.cjs; sdk-smoke amqp/blob/eventhubs -> burned copies under docs/jira/v26.10.18/burn/ (not live tests).
- sdk_coverage.py (executed): python3 scripts/sdk_coverage.py exit 1, "GATE: FAIL (40 findings)"; failing cap-cells (ground=FAIL, e.g. monitor-metrics, eh-consumergroups, tags-at-scope) are outside this ticket's owned files. Acceptance part 1 NOT met.
- AZ2-matrix.json: all 7 cells remain HAVE-TESTED (file presence), pass_state UNVERIFIED; no mix test executed this lane.
