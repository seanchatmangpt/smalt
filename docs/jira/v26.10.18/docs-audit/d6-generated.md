# D6 — generated artifacts audit (2026-10-18)
CURRENT: ERROR_CODES.md (--check pass), capabilities.json (canonical trim-trailing pass, 41 caps), THIRD_PARTY.md (byte-exact), REGISTRY.md (manual verify), FLAKE_LEDGER.md (derive commands pass).
STALE: v26.10.18 RECEIPTS.md + receipts/INDEX.md (4 unindexed receipts: azb-14-sigkill-storm, i24-warnings, i25-churn-sizing, i25-kill-storm-host; count 71->75; "Generated 2026-10-15" stamp); spillover v26.10.14/.16 aggregates (spc-bands FAIL->SUSPECT, suspect counts). Fix: just receipt-index.
TEST_ISOLATION.md — worst offender: async:true inventory wrong (management_rpc flipped false; 6 new async:true files unlisted — substantive "no async:true touches Store" claim verified holding); Store.clear inventory 8-stale/21-missing (raw: 39 files/53 sites + 2 lib); zero mention of the isolation court (AZB-11) or SleepWindows.
Integrity: receipt_index.py ignores argv (--help triggers full regen) — flagged.
