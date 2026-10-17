# r235 — mix.exs `test.compliance` alias: first witnessed run FAILS (40 failures)

- Date: 2026-10-17
- Lane: I2 (WO-3)
- Subject: in-flight working-tree diff `mix.exs` — new alias
  `"test.compliance": ["test --include amqp_wire test/compliance_test.exs"]`
  plus its `preferred_envs` entry (uncommitted)
- Standing: PARTIAL_ALIVE

## Command

```
$ mix test.compliance
```

## Real output (2026-10-17, /Users/sac/smalt)

```
Finished in 6.6 seconds (0.00s async, 6.6s sync)
173 tests, 40 failures
EXIT=2
```

Failure distribution by module (exact grep over `/tmp/i2-compliance.log`):

```
$ grep -E "^\s+[0-9]+\) test" /tmp/i2-compliance.log | grep -oE '\((Smalt\.[A-Za-z0-9_.]+Test)\)' | sort | uniq -c | sort -rn
  19 (Smalt.Compliance.C4BlobTest)
   6 (Smalt.Compliance.C1ArmTest)
```

Sample failure (exact log lines):

```
  1) test stale api-version error names the exact latest version for the type (Smalt.Compliance.C1ArmTest)
     test/compliance/c1_arm.exs:254
     Assertion with == failed
     code:  assert err["code"] == "InvalidApiVersionParameter"
     left:  "InvalidResourceShape"
```

## Correlation with in-flight lane edits

The git-status snapshot shows in-flight edits on exactly these surfaces:
`lib/smalt/data_plane/blob_service.ex`, `lib/smalt/data_plane/blob_storage.ex`,
`lib/smalt/mcp/router.ex`, `lib/smalt/arm_gateway/router.ex`,
`lib/smalt/auth/bearer.ex` — the failing modules' collaborators. The 40
failures therefore correlate with in-flight `lib/` diffs from concurrent
surface lanes, not with the landed WO-1 commits (r232-r234 replayed clean,
exit 0). Under the compile-freeze SLA this is routed to the owning lanes.

## Routed to

Coordinator: 40 compliance failures concentrate on C4Blob (19) + C1Arm (6);
owning lanes of the in-flight `lib/` diffs on the blob/arm/auth surfaces.
This lane did NOT fix or revert them (lease: receipts only).
