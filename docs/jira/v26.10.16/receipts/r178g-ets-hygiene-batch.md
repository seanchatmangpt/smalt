# Receipt — R178g / R189 / R195 (ETS hygiene + test cleanup batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 late docs sweep, lane 267)
- **Standing:** PASS (R178g, R189, R195)
- **Date:** 2026-10-16 (W-late docs lane, batch 5 of 5)

## What landed

- **R178g** (strata cleanup + ETS hygiene): on_exit-style record-and-delete
  guards so seeded `:smalt_resources` rows never leak across tests — markers
  at `test/strata_compat_test.exs:272` ("R178g disclosure (minimal unblock
  fix, owner lane R178g store.ex)"), `test/mcp_test.exs:40`,
  `test/mcp_wire_test.exs:18`, `test/smalt_arm_gateway_test.exs:701`
  ("clean up seeded :smalt_resources rows (rg-a/rg-b/rg-p, 104 keys)"),
  plus the success-path `:ets.delete` in the CAS test. Non-vacuity court:
  `scripts/shim_court/strata_cleanup_court.sh` (shims the cleanup out and
  proves the non-map-row leak reproduces).
- **R189** (on_exit cleanup in the 3 test files): on-disk `on_exit` blocks
  verified in `test/store_churn_test.exs:17`, `test/strata_compat_test.exs:278`,
  `test/mcp_test.exs:46/:903` — the cleanup landed; covered by the suites
  re-run below.
- **R195** (management_rpc wire-form merge): `lib/smalt/messaging/amqp/management_rpc.ex:878`
  — "lane 243: wire form kept — `{:uuid, LockManager.token_to_wire/1}` —
  string" (the .NET-GUID lock-token wire dialect merge; two-dialect token
  formatting at management_rpc.ex:749-762). Covered by
  `test/amqp/management_rpc_test.exs` (33/0 below).

## Verification (2026-10-16, lane 267, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane267 mix test test/store_churn_test.exs test/strata_compat_test.exs test/mcp_test.exs test/smalt_arm_gateway_test.exs
102 tests, 0 failures
exit=0
$ bash scripts/shim_court/strata_cleanup_court.sh
[AFTER] flip proven: shimmed CAS test left the non-map row live in the shared table; the appended witness re-asserted the churn is_map law on the real shared ETS
.........SHIM-COURT: NONMAP leak reproduced: ["v2"]
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] strata_cleanup_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
$ MIX_BUILD_ROOT=_build-lane267 mix test test/amqp/management_rpc_test.exs
33 tests, 0 failures (3 excluded)
exit=0
```

(strata_cleanup court true exit re-confirmed in a clean re-run: exit=0.)

## Disposition of remaining unlocated ids

- **R185j, R186, R193, R201**: no on-disk markers found (`grep -rn` over
  `lib/ test/ scripts/ gates/ docs/jira/v26.10.16/` returns nothing
  attributable for any of them). Recorded as unlocated — these ids carry no
  verifiable artifact on this tree; standing UNKNOWN, not claimed as landed.

## Standing

- **R178g**: PASS — suites 102/0 + court non-vacuous (leak reproduces under
  shim, restore byte-exact).
- **R189**: PASS — on_exit blocks on disk in all 3 named test files,
  suites green.
- **R195**: PASS — wire-form merge marker in-source, management_rpc 33/0.
- **R185j/R186/R193/R201**: UNKNOWN (unlocated on this tree; do not credit).
