# i29 — Lane-C put_restored env-sweep behavior verification (5-file sample)

Date: 2026-10-18
Context: slice(5-file sample)
Standing: PASS (sample) / [IN-FLIGHT] (no Lane-C sweep receipt found)
Subject: uncommitted Lane-C sweep across 10 dirty test files (13 named; 3 — mcp, smalt_arm_gateway,
arm_cors… see status note) at HEAD 334f3f8.

## 1. Dirty state (git status --porcelain test/)

10 files modified, none committed:
broker_facade, flow_credit, frame_codec, sas_verifier (test/amqp/), arm_cors,
sovereign_midnight, lro, smalt_ets_baseline_identity, wire/arm_wire,
wire_tier_refusal_sweep. The named 13 vs observed 10 delta: mcp, mcp_wire,
smalt_arm_gateway show clean in `git status --porcelain test/` at snapshot time.

## 2. Sample runs (scripts/fast_test.sh, per-hash private build roots _build-ft-*)

| file | result |
|---|---|
| test/amqp/sas_verifier_test.exs | 35 tests, 0 failures (wall 6s) |
| test/amqp/flow_credit_test.exs | 0 tests, 0 failures (7 excluded — `@moduletag :amqp_wire`, excluded by default tier; expected, not a sweep regression) |
| test/wire/arm_wire_test.exs | 6 tests, 0 failures (wall 232s incl. cold compile) |
| test/mcp_wire_test.exs | 33 tests, 0 failures (wall 214s) |
| test/wire_tier_refusal_sweep_test.exs | 3 tests, 0 failures (wall 157s) |

All exits 0. Aggregate: 77 tests run, 0 failures across 5 files. flow_credit's
excluded body is pre-existing tier exclusion, not introduced by the sweep; the
sweep's `put_restored` call at line 50 compiles clean.

## 3. Lane-C receipt search

grep of docs/jira/v26.10.18/receipts/ for env-sweep/put_restored-named receipts
newer than checkpoint3 (22:58): none found (matches were older or unrelated:
i29-isolation-count, i29-leak-remediation, azb-11b, w*-review).

## Verdict

Behavior held on the 5-file sample. Lane-C sweep is still in flight — no sweep
receipt postdates checkpoint3 → [IN-FLIGHT]. Diff scope: 10 files, +61/−164.

Commands: `git status --porcelain test/`; per-file
`./scripts/fast_test.sh <file>` (5 runs, exits 0).
