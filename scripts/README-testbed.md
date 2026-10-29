# Popcorn Testbed: Live Gate Non-Vacuity Court

Chicago-school anti-vacuity proof for the browser smoke witness gate
(`popcorn_demo/scripts/browser_smoke.mjs`). A gate that cannot fail is
vacuous; this court proves the gate's exit arms are real and that a mutated
always-pass shim flips the outcome.

## Run

```bash
bash "$(dirname "$0")/../scripts/live_gate_court.sh"  # repo-relative
```

No dependencies beyond `bash`, `python3`, `node`, `shasum`. Never launches a
browser; safe to run on any machine.

## What it proves

1. **BASELINE** — the real gate contains all three exit arms:
   `live=OK` (exit 0), `allowOffline ? 0 : 3` (SKIP), `live=FAIL` (exit 1).
2. **BEFORE/SHIM** — on a temp COPY only (marked `SHIM-COURT`), the exit
   logic is replaced with an unconditional `process.exit(0)` plus a
   `SMOKE_COURT_ONLY` early-exit guard. Running the copy under
   `SMOKE_COURT_ONLY=1` must exit 0 — the flip is the non-vacuity proof
   (a court that cannot flip is FAIL).
3. **AFTER** — the REAL gate carries no `SMOKE_COURT_ONLY` backdoor and all
   three arms intact. PROOF-MODE is structural (grep), not execution: the
   real gate launches headless Chromium + the wasm BEAM, so execution is
   replaced by the structural assertion plus the flipped shim run.
4. **RESTORE** — sha256 of the real gate re-compared byte-exact against the
   BEFORE hash; any drift fails closed as `SUBJECT-CORRUPTED`.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | PASS — gate is non-vacuous, subject untouched |
| 1 | FAIL — named reason (`GATE-INCOMPLETE`, `NO-FLIP`, `BACKDOOR-LEAK`, `SUBJECT-CORRUPTED`, …) |
| 3 | Loud SKIP — gate file missing (never a faked pass) |

## Idempotence

Stateless: the shim lives on a temp copy deleted on exit; the real gate is
read-only to the court. Safe to re-run.
