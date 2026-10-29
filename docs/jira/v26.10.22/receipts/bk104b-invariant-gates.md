# BK-104b — Invariant Gates Full Re-run (Toolchain Self-Resolution)

**Standing: ALIVE**
**Context: full**
**Date:** 2026-10-21 · **Head:** `d08581441186f938a3a0c9f9cb92a275f1ef1360` (main, uncommitted lane edits present in lib/workspace/test — none touched `gates/`)
**Command:** `python3 scripts/invariant_gates.py` (suite exit **0**)
**Method:** no manual PATH manipulation; each gate logged
`toolchain: elixir 1.20.4-otp-29 / OTP 29.1.2 (resolved from .tool-versions -> asdf installs)`
— confirms BK-72 common.py resolution on all 6 gates. BK-78 queue-capacity repair held.

## Per-gate verdicts

| Gate | Verdict | Suite exit | Notes |
|---|---|---|---|
| appconfig-etag-cas | PASS | 0 | positive + 6 fixtures refused; 1×200/1×412 race, etag formula, winner-identity |
| blob-worm | PASS | 0 | positive + 6 fixtures refused; overwrite/delete/snapshot under hold → 409 ContainerLocked |
| cosmos-etag-cas | PASS | 0 | positive + 9 fixtures refused; 1×200 + 5×412 race, KD-148 GUID etag shape |
| ledger-chain | PASS | 0 | positive + 6 fixtures refused; ran green **under load** (see below) |
| lock-clamp | PASS | 0 | positive + 4 fixtures refused; PT1H clamp delta 29999ms within [29900,32000] |
| queue-capacity | PASS | 0 | positive + 4 fixtures refused; `amqp:link:message-size-exceeded` + `:capacity` detach, connection survived (BK-78 repair confirmed) |

**Result: 6/6 PASS** (`[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused).`)
Receipts: `tmp/invariant-gates/<gate>-receipt.json` (6, fresh).

## Machine load samples (during run)

- loadavg at mid-run sample: **17.96 / 26.33 / 62.41** (1/5/15min — 15min tail elevated, decaying)
- CPU: 25.7% user, 3.4% sys, **71.5% idle**; PhysMem 46G used, 988M unused (3.1G wired, 875M compressed)

Load was substantial (15-min avg 62) but the full suite passed on the first run — no
load-class failures, no environment-class failures, no real defects to dispatch.

## Falsifier status

Would falsify: any gate FAIL/SKIP, any negative fixture accepted, toolchain resolution
falling back to manual PATH. None observed.

## See Also

- `docs/jira/v26.10.22/receipts/` (BK-72/BK-78 lanes)
- `gates/common.py` (`.tool-versions` → asdf resolution)
