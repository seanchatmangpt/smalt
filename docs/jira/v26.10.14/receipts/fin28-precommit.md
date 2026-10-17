# fin-28 — Final Pre-Commit Checklist

**Release**: v26.10.14 · **Lane**: fin-28 · **Date**: 2026-10-15 · **Agent**: checklist runner
**Gate condition**: poll for S/X lane receipts s1/s2/s3/s4/s5 + x10-s-wave-integration, up to 45 min.

## Gate outcome

- Poll ran ~50 min total (45 min budget + 5 min grace, incl. a wait spanning the
  coordinator's 5-commit integration landing `985c41e..b88c8b5`).
- Present: `s2-eh-shims.md`, `s3-kv-challenge.md`, `s4-wire-normalization.md`, `s5-hil-virtual.md`.
- **Missing: `s1` and `x10-s-wave-integration` — never landed.** Checklist executed anyway
  (checklist value is gate-independent; classification below reflects the gap).

## Checklist (executed 2026-10-15, exact commands + exits)

| # | Check | Command | Exit | Classification of non-green |
|---|---|---|---|---|
| 1 | Tree quiescence | `git status --porcelain \| wc -l` twice 60s apart | 166→3→0 (clean after coordinator commits `b88c8b5..985c41e`); **re-dirtying during this checklist: 34 files M (bench scripts, `egress_router.ex`, bench jsonl)** | Tree NOT quiescent — concurrent lanes still landing. Mechanical-from-session (in-flight lanes), not a defect. |
| 1b | — | — | — | s1/x10 receipts missing (see Gate outcome). Real gap, not fixed (belongs to those lanes). |
| 2 | Compile | `mix compile --warnings-as-errors` | 0 | GREEN |
| 3 | doctor.py | `python3 scripts/doctor.py --json` | 0 | GREEN (all checks PASS; substrate NOT-RUNNING info only; 1/16 receipts >24h — advisory) |
| 4 | doctor-dod | `just doctor-dod` | 0 | GREEN with 2 WARN (orphan lock `/tmp/smalt-substrate.lock` with no live listeners; 1 lane build-root lease, 342.1 MiB, `just lane-clean` remediation) — non-failing, recorded |
| 5 | naming_sweep | `bash scripts/naming_sweep.sh` | **1 (FAIL: 22 violations, 52 allowed)** | **Real, not fixed.** All 22 are hard-coded `/Users/sac/smalt` absolute paths in committed v26.10.14 bench receipt JSONL (a9/b4), v26.10.15 planning docs, and `scripts/bench/*`, `scripts/shim_court/*` landed by other lanes' commits this window. Fixing means rewriting committed receipt/doc content owned by other lanes — reported, not repaired. |
| 6 | gen_error_codes | `python3 scripts/gen_error_codes.py --check` | 1 → regen → re-check **0** | GREEN after regen (70 rows → `docs/ERROR_CODES.md`). Staleness was mechanical-from-session (`egress_router.ex` annotations moved while lanes land); regen permitted by task, witnessed. |
| 7 | gap-sync | `just gap-sync` | 0 | GREEN ("KD register census floors hold; WIRE_PARITY census matches lane-13: 5 CLOSED + 9 typed-UNSUPPORTED; no contradictions") |
| 8 | sobelow | `just sobelow` | 0 (non-blocking) | GREEN — 27 findings, all Low Confidence (e.g. `lib/smalt/tls.ex:311` File.rm traversal, Low). Triage: `receipts/errc8-sobelow.md` |

## Verdict

- **Gate condition NOT met**: s1 + x10-s-wave-integration receipts never landed within the 45-min
  poll window (+grace). The integration commits landed without them.
- 6/8 checks green-or-recovered; 1 real non-green (naming_sweep, 22 absolute-path violations in
  other lanes' committed files); 1 gate gap (missing s1/x10 receipts).
- Tree re-dirtied mid-checklist (34 files M) — checklist ran on a moving tree; compile/error-codes
  checks re-verified against the landed state after regeneration.
- No commits made by this lane, per task.
