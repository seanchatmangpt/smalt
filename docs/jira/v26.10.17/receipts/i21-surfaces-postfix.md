# i21 surfaces postfix — verification lane receipt

Context: /Users/sac/smalt
**Standing:** PARTIAL_ALIVE (2 of 3 surfaces green; naming-sweep RED).

## Dependency wait

`docs/jira/v26.10.17/receipts/i21-full-suite-postfix.md` was **never written**. Polled at
120 s intervals for >30 minutes (try budget of 15 exhausted, ~21 polls run). The full-suite
lane was still mid-flight while this lane ran: `git status` showed a large concurrent
modification set (lib/smalt/**, mix tasks, docs/jira residue) beyond the two files dirty at
dispatch (`test/amqp/broker_facade_test.exs`, `test/store_dets_test.exs`). Surface
re-verification below therefore ran against a tree with other lanes' in-flight edits.
No edits, no git actions taken by this lane.

## Surface results

### 1. `just ws-court` — PASS

```
# court verdict
# PASS=50 FAIL=0 SKIP=2
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node
# SKIP: live: ARM read-only probe: no smalt substrate on http://127.0.0.1:9443 (ECONNREFUSED)
```

Both SKIPs are the documented loud-skip classes (node-inexecutable DOM leg; no substrate
booted for the live leg). 0 FAIL as expected.

### 2. `just naming-sweep` — FAIL (exit 1)

```
[NAMING-SWEEP] FAIL: 60 violation(s), 46 allowed
error: recipe `naming-sweep` failed on line 158 with exit code 1
```

All 60 violations are the same class: absolute `/Users/sac/smalt` paths inside
`docs/jira/v26.10.17/verify-ledger/w0-*.md` / `w1-*.md` (evidence_command lines and
Repo: headers) plus `RECEIPT_CONTEXT_LAW.md:3`, `WO4-RUNBOOK.md:40`, `RELEASABLE.md:21`,
`FINAL.md:20`. Baseline before this window's verify-ledger wave was **1 violation / 46
allowed** (the parked RECEIPT_CONTEXT_LAW.md hit, recorded in FINAL.md:20). The 59 new
violations are introduced by the in-flight verify-ledger lane's uncommitted files, not by
this lane. Not repaired: this lane is verification-only.

### 3. `just sdk-matrix` — PASS (exit 0)

```
capability cells: PASS=4 PASS-PARTIAL=3 REGISTERED-DIVERGENCE=0 UNREGISTERED-GAP=0 MISSING=0
GATE: OK — every cell pass / registered / sim-pass / missing-registered
```

Notable rows: KD-92 (blob/ts) and KD-93 (cosmos/ts) remain OPEN REGISTERED-DIVERGENCE —
expected, registered in the KD table.

## Machine

`just bench-machine`:
```json
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Verdict

- ws-court: 0 FAIL — green.
- sdk-matrix: exit 0 — green.
- naming-sweep: RED, 60 violations (1 parked baseline + 59 from the in-flight
  verify-ledger lane's absolute paths). Close condition: the verify-ledger files switch to
  repo-relative paths (or the sweep allowlist is extended by the owning lane), then
  naming-sweep returns to the 1-parked-violation baseline.
- Full-suite dependency receipt absent at time of writing; this receipt covers surfaces
  only and does not stand in for the mix-tier result.
