# D11 — agent-config docs audit (2026-10-18)
Stale (5): CLAUDE.md:27 "5 fail-closed gates" (now 6, appconfig-etag-cas); :23 verify-all stages list missing test-stress/test-budget/sleep-gate; :101 "model/smalt.yaml" path (now lib/smalt/telemetry/semconv/model/); :112 bare RECEIPT_CONTEXT_LAW.md filename unresolvable (docs/jira/v26.10.17/); :44-51 test ladder omits :stress exclusion.
Undocumented conventions (3): stress tier (just test-stress + census fence), budget gate (just test-budget + manifest), planes (SMALT_PLANES + azsim-sdk + ports-and-planes doc).
Clean: commands table, test ladder recipes, agents list, generated-artifacts targets, ~/.claude/rules/testing-chicago-style.md, no-sleep-testing.md.
