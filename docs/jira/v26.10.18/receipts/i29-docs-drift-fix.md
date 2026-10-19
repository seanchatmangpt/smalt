# I29 — docs content-drift fixes (follow-up to i29-docs-diaataxis)

Standing: PASS
Date: 2026-10-18
Scope: the 4 content-drift items reported (not fixed) in
`docs/jira/v26.10.18/receipts/i29-docs-diaataxis.md`, plus its :7 H1 item.

## Fixes applied

1. `docs/TEST_ISOLATION.md` §7 (now :286-293): SleepWindows signatures
   corrected against `test/support/sleep_windows.ex` ground truth
   (`grep -n "def "` — 6 defs):
   `second_boundary_ms/1`, `fixed_window_rollover_ms/1`,
   `lro_delay_elapse_ms/2`, `lro_deadline_elapse_ms/1`,
   `sweeper_grace_elapse_ms/2`, `mcp_idle_gap_ms/1`.
   Removed `lro_retention_elapse_ms/1` (function does not exist).
   Consumer list re-derived from `grep -rln "SleepWindows\." test/` →
   5 real callers (`sweeper_test`, `arm_error_corpus_test`, `c1_arm`,
   `mcp_wire_test`, `smalt_arm_gateway_test`); dropped
   `test/enclave-testbed/enclave_testbed.exs`, which only references
   SleepWindows in a comment, never calls it.
2. `docs/TEST_ISOLATION.md:41` — "ownered exception" → "owned exception".
3. `docs/TEST_ISOLATION.md:7` — second H1 demoted to H2
   (`## Smalt Test Isolation Contract`); both texts kept, one-H1 conformant.
4. `docs/reference/burn-receipt-schema.md:49` — "one of the ten DfCM
   terms" → "one of the nine DfCM terms" (the inline list has exactly
   9 entries: mu_on_O, admission_vacuous, mu_unlawful,
   R_missing_identity/authority/consequence/replay/standing,
   R_not_fed_back).
5. `docs/how-to/how-to-add-config-key.md:52-53` — truncated quote
   repaired against the actual test comment
   (`test/config_replay_identity_test.exs:64-66`): now reads
   `the test comment says: "census pin updated with the ticket, not
   silently drifted"`. No new policy invented; the quote is the test's
   own words.
6. `docs/NO_SLEEP_DOCTRINE.md:63` — trailing whitespace after
   `` `GenServer.call`, `` removed.

Not touched (per task scope): over-100-char table lines (owner-lane
call), docs/jira/ receipts, WIRE_PARITY GAP tokens.

## Verification (real output, post-edit)

```
$ grep -nE 'fixed_window_rollover_ms/0|lro_retention_elapse_ms|sweeper_grace_elapse_ms/0|mcp_idle_gap_ms/0' docs/TEST_ISOLATION.md
-> exit=1 (zero matches)
$ grep -n "ownered" docs/TEST_ISOLATION.md
-> exit=1
$ grep -c "^# " docs/TEST_ISOLATION.md
-> 1
$ grep -n "ten DfCM" docs/reference/burn-receipt-schema.md
-> exit=1
$ grep -n 'not" silently' docs/how-to/how-to-add-config-key.md
-> exit=1
$ grep -cn ' $' docs/NO_SLEEP_DOCTRINE.md
-> 0
$ grep -n "fixed_window_rollover_ms/1\|^## Smalt Test Isolation Contract" docs/TEST_ISOLATION.md
7:## Smalt Test Isolation Contract
292:`second_boundary_ms/1`, `fixed_window_rollover_ms/1`, `lro_delay_elapse_ms/2`,
```

## Receipt context

Context: solo (single lane; no concurrent writers on the touched files)

## Conclusion

All 4 reported content-drift items + the double-H1 structural item are
closed with post-edit drift greps at zero matches; §7 now matches
`test/support/sleep_windows.ex` and the real consumer grep exactly.
