# i29 — E2E tier full re-verify post-fixes

Date: 2026-10-19 · Context: slice(7 scenarios) · Repo: /Users/sac/smalt
Skipped per dispatch: s1_iac_chain, s3_pipeline, s7_worm (canonical-port BLOCKED-ENV).
Ran sequentially, port 9443 free before start (lsof empty).

## Verdicts (all exit 0, zero failures)

| Scenario | Exit | Pass count | Evidence |
|---|---|---|---|
| s2_byok | 0 | 9/9 (node: tests 9, pass 9, fail 0) | `[byok-run] ALL BYOK STEPS PASS` |
| s4_oauth_negatives | 0 | 12/12 SECURITY-PASS (merged receipt) | test/e2e/s4_oauth_negatives/receipt.json: total=12 SECURITY-PASS=12 KNOWN-GAP=0 |
| s5_sessions | 0 | 6/6 (tests 6, pass 6, fail 0) | `[s5-run] PASS` |
| s6_checkpoints | 0 | 200/200 events, 4 consumers, exactly 200 CAS wins, zero double-processing | `EXACTLY_ONCE_OK`, `zero_double_processing: true` |
| s8_cosmos_race | 0 | 8/8 steps PASS (incl. CAS race: 1x200 + 7x412, no lost update; 160/160 bulk 201; session token monotonic) | RECEIPT JSON verdict PASS |
| s9_lro_chain | 0 | 7/7 (tests 7, pass 7, fail 0) | `[s9-lro-chain] PASS` |
| s10_attest_adversary | 0 | 11/11 attacks PASS + dead-substrate control PASS | test/e2e/s10_attest_adversary/.logs/receipt.json; `COURT PASS` |

Aggregate: 7/7 scenarios exit 0; 53/53 assertions PASS (9+12+6+200-event ex once+8+7+11);
0 errors, 0 skips, 0 flakes.

## Notes

- s9 printed a benign `Killed: 9` on the foreground mix run during teardown
  (after `PASS`, exit 0) — substrate shutdown kill, not a test failure.
- s8 transport note (pre-existing, receipted in-scenario): azure-cosmos SDK
  attempted, raw loopback HTTP executed.

## Standing

ALIVE — full E2E tier green post-fixes, x1 warm run.
