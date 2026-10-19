# i29 — Static gate quad re-run, pre-gate 2 (azb-20 landed, G1 queue_storage.ex present)

Date: 2026-10-19 · Context: solo(/Users/sac/smalt) · WO: i29 · Actor: bench-runner lane

## Subject

Re-run of the four static gates after the azb-20 whitelist work landed and
`lib/smalt/data_plane/queue_storage.ex` (G1) appeared on the tree.

## Commands + exits

```
$ python3 gates/test_isolation_leak_gate.py
verdict=PASS tree=GREEN offenders=0 fixtures_refused=True
receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
EXIT=0   (172 .exs scanned, 17 allowlisted, positive fixtures all as-expected)

$ just sleep-gate
[SLEEP-GATE] PASS — 339 files, 0 unclassified sleep primitives
EXIT=0

$ just naming-sweep
[NAMING-SWEEP] VIOLATIONS (4):  ... [NAMING-SWEEP] FAIL: 4 violation(s), 49 allowed
EXIT=1

$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
EXIT=0
```

## Findings

- **naming-sweep RED — 4 violations, one class.** All four are new
  cgroup-soak run receipts quoting `/Users/sac` at line 6:

  - `docs/jira/v26.10.18/burn/cgroup-20261019T063833Z.jsonl:6`
  - `docs/jira/v26.10.18/burn/cgroup-20261019T064350Z.jsonl:6`
  - `docs/jira/v26.10.18/burn/cgroup-20261019T065557Z.jsonl:6`
  - `docs/jira/v26.10.18/burn/cgroup-20261019T064704Z.jsonl:6`

  Same machine-receipt class already handled twice: line-precise allowlist
  entry for the earlier soak receipt
  (`docs/jira/v26.10.18/burn/cgroup-20261019T061643Z.jsonl:6`,
  `scripts/naming_sweep.sh:97`) and directory-level exclusion for
  `docs/jira/*/bench/` (same absolute-path-quoting class,
  `scripts/naming_sweep.sh:20-22`). Each flagged line is the
  `replay.commands[0].cmd` of a `validate_burn.py --gate` run receipt
  quoting its own environment. Not fixed from this lane: the allowlist /
  exclusion list is shared gate infra; coordinator owns the edit (either 4
  line entries or extend the `docs/jira/*/bench/`-style exclusion to
  `docs/jira/*/burn/*.jsonl` machine receipts).

- **error-codes**: `--check` clean, no regen needed — the previous regen
  held; the newest lib edits (including queue_storage.ex) introduced no new
  drift.

## Verdict

3/4 GREEN (isolation-leak PASS, sleep-gate PASS, error-codes clean).
naming-sweep FAIL with 4 known-class machine-receipt hits, coordinator
decision pending. Quad is RED on naming-sweep alone.

## Standing

PARTIAL_ALIVE — three gates green on live output; naming-sweep red with the
finding named and the fix class identified but not applied from this lane.
