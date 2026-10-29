# BK-NFRD1 — PRD §3 NFR-DUR-002 citation fix (BK-NFRV D1 follow-up)

**Standing: ALIVE** — `just docs-dod-check` exit 0 after edit. `Context: solo`
Lane: BK-NFRD1 · Date: 2026-10-22 · Subject: `docs/jira/v26.10.22/PRD.md` (one cell, line 50) · Parent audit: `receipts/bknfrv-nfr-audit.md` DRIFT row D1.

## Finding — D1's premise was itself stale

BK-NFRV D1 claimed "no receipt on disk is labeled JA-7". Disk check:

```
$ grep -rln 'JA-7\b\|JA7' docs/jira/v26.10.2{1,2}/receipts/
→ docs/jira/v26.10.21/receipts/ja7-crash-only-court.md   (present, Standing: ALIVE)
```

The label **resolves**. `ja7-crash-only-court.md` (v26.10.21) is the JA-7
crash-only court receipt: 6/6 legs, green ×2 consecutive runs
(`Result: 6 passed`, run 3 embedded), OTP-29 toolchain, `MIX_BUILD_ROOT=_build-ja7`.
So the fix is NOT a label re-point (BK-NFRV's proposed target
`amqp10-court-closure.md` is the closure receipt, not the JA-7 receipt) — the
real defect in the cell was the **number claim**: the receipt's embedded
output is

```
[JA-7.3] cycle cascade ms: 1 0 0 0 0 0 0 0 0 0
```

i.e. 9×0ms + 1×1ms over 10 cycles, not "0ms cascades ×10 cycles" as the PRD
cell asserted.

## Edit (before → after)

Before:

```
| NFR-DUR-002 | Cascade ≤1.0ms | JA-7 crash-only court: 0ms cascades ×10 cycles |
```

After:

```
| NFR-DUR-002 | Cascade ≤1.0ms | JA-7 crash-only court (`../v26.10.21/receipts/ja7-crash-only-court.md`, ALIVE): 10 crash-recover cycles, cascade ms measured `1 0 0 0 0 0 0 0 0 0` — ≤1ms every cycle, 0ms in 9/10; closure receipt `amqp10-court-closure.md` PASS ×2 |
```

The corrected claim still supports the ≤1.0ms requirement (leg JA-7.3 court
deadline ≤1 ms/cycle, all cycles ≤1ms) — overclaim removed, anchor now
receipt-pathed.

## Label sweep (task 2)

Every JA-n label cited in PRD.md re-resolved against receipts on disk:

| PRD cite | Receipt | Standing |
|---|---|---|
| JA-7 (§3 NFR-DUR-002) | `../v26.10.21/receipts/ja7-crash-only-court.md` | ALIVE |
| JA-R3 (§2 FR-SVR-006, §3 NFR-SEC-001/002, §4 COURT-ATOM-CLAMP, §5 Gate 0) | `../v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` | PASS |
| ja5 (§2 FR-RET-002, §3 NFR-SEC-001) | `../v26.10.21/receipts/ja5-fail-fast-court.md` | PASS (ALIVE) |

No other drift — no further edits.

## Gate

```
$ just docs-dod-check
... (57 OK lines) ...
kd-receipt-fence: checked 317 receipt cites across 6 registers -> OK
EXIT=0
```

## Falsifier

Any PRD JA-n cite whose receipt file is absent, or whose cell number is not
reproducible from the receipt's embedded output → DRIFT. The number
discrepancy (0ms×10 vs 1 0 0 0 …) is the branch that fired here.
