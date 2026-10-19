# Receipt — V261019-15 (verification-gates)

Context: solo(V261019-15) — all gate runs below executed by this lane, 2026-10-19 ~10:08–10:12 PDT.
Standing: **ALIVE** — the fail-closed verification gates exist and were
executed this session with real, honest verdicts: one PASS, one RED
(exit 1 — recorded, not suppressed), one docs-gate PASS. Outputs below are
this session's.
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- Consolidated verification gates for the reset window:
  - `scripts/non_duplication_gate.py` — non-duplication law over the
    residual tier (`test/internal/**`): R1 transport usage (absolute),
    R2 Azure status literals + assert-verb co-occurrence, R3 JSON-shape
    asserts; typed exemptions in `scripts/non_duplication_classes.json`;
    fail-closed (exit 1 on zero files scanned / unreadable file / unreadable
    classes file). Exit contract: 0 clean / 1 violation.
  - `scripts/portable_target_gate.py` — the `verification/{ts,py}` suites
    must run against official Azure SDKs + stdlib only (no `lib/smalt`, no
    `mix run`, no `smalt-cli`, no `/Users/` paths, env reads restricted to
    `SMALT_AZURE_*`/`AZURE_*`/documented overrides). Exit 0 clean / 1
    violation.
  - `just docs-dod-check` — every receipt path named in user-facing docs
    exists on disk.
- Not wired (disclosed): `just receipt-index` was not run by this lane —
  `RECEIPTS.md` and `receipts/INDEX.md` are coordinator-generated at wrap;
  this lane does not regenerate them.

## Verification (real output tails)

```
$ python3 scripts/non_duplication_gate.py
[PASS] non-duplication gate: 6 file(s) clean
exit=0
```

```
$ python3 scripts/portable_target_gate.py > /tmp/ptg.out 2>&1; echo "ptg_exit=$?"
ptg_exit=1
$ grep -c violation /tmp/ptg.out
112
```

Sample RED lines (honest failure, first of 112):

```
/Users/sac/smalt/verification/ts/node_modules/which-typed-array/index.js:6: disallowed import: call-bound
/Users/sac/smalt/verification/ts/node_modules/wsl-utils/index.d.ts:73: HARD violation (absolute home path): const windowsPath = ...
```

Disposition (measured): all 112 violations originate in
`verification/ts/node_modules/` (installed third-party transitive deps) or
`.venv` editable-install finder stubs or README prose — none in
lane-authored suite code inspected. The gate currently scans third-party
trees; scanner exclusions are the suite owners' (V261019-08/09) open item.
The exit-1 is recorded as-is; a green would be fabricated if these hits
were suppressed without a scanner change.

```
$ just docs-dod-check  (tail)
OK    docs/jira/v26.10.18/FINAL.md
OK    docs/jira/v26.10.18/RECEIPTS.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
exit=0
```

## Acceptance greps

- Gate wiring present: `grep -l "non_duplication_gate\|portable_target_gate" scripts/ justfile.d/` — both scripts exist and execute (outputs above).
- `EXPECTED_` census reconciliation in `scripts/doctor_dod.py` — not touched
  by this lane; no count changes to cite.

## Deviations

1. `just court` / `just receipt-index` not executed: court is the
   coordinator's serialized close gate (court-x2 NOT-RUN, see V261019-12);
   receipt-index regenerates coordinator-owned artifacts. Standing ALIVE
   covers the three gates executed above only.
