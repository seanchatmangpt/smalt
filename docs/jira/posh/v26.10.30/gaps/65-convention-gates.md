# 65 — Convention Gates (lane 12)

**Verdict: ALIVE** — gates run clean (`just convention-gates`, exit 0) and the
non-vacuity court witnesses all four gates flipping.

## Surface

`scripts/convention_gates.sh` + `just convention-gates` (justfile recipe with
disclosed court command). Exit contract: 0 = all PASS (WARN allowed), 1 = any
FAIL, 2 = usage.

## Gates

1. **G1 UNSUPPORTED-honesty** — scans code surfaces (`apps/`, `packages/`,
   `scripts/`, `infra/`; .ts/.ex/.go/.sh/.tf) for `UNSUPPORTED` markers. Any
   marker without same-line warn/diag/test emit context is a FAIL with
   file:line. Current tree: 0 markers (loud zero). Court flip: bare
   `UNSUPPORTED(legacy)` fixture → G1 FAIL, exit 1. Witnessed.
2. **G2 generated-file integrity** — regenerates `receipts/INDEX.md` via
   `scripts/receipts_index.sh --emit-index` and byte-compares, excluding two
   disclosed volatile fields: the header wall-clock timestamp line and the
   INDEX.md self-row (its mtime changes every emit). On drift the pre-gate
   bytes are restored sha256-exact before failing — the gate never leaves the
   tree mutated. **Current status: loud SKIP** — the posh estate (incl.
   `receipts_index.sh`) was delegated to `SMALT_ROOT` mid-lane by another
   lane's transition (justfile now wraps `{{SMALT}}/scripts/...`), and that
   generator `cd`s to its own repo root, so running it would emit *smalt's*
   INDEX, not this repo's — a false gate. SKIP names this reason. Court flip
   via temp-root local generator fixture: clean→exit 0, drift→exit 1 with
   FAIL + sha256-exact restore. Witnessed. Re-enable by restoring a local
   `scripts/receipts_index.sh`.
3. **G3 SKIP-carries-reason** — every SKIP-emitting `echo`/`printf` line in
   `scripts/*.sh` + `justfile` must carry a reason on the same line (literal
   text or a `%s`/`%d` placeholder fed by a reason argument). FAIL with
   file:line otherwise. Count varies with tree state (0–2 lines checked this
   session as lanes moved `posh_doctor.sh`). Court flip: `echo "[X-SKIP]"`
   fixture → G3 FAIL, exit 1. Witnessed.
4. **G4 disjunctive-law lint (flag-not-fail)** — test files referencing
   `SESSION_SECRET`/secrets must assert BOTH branches (omitted and
   echoed/redacted); single-branch tests are flagged as WARN with file:line,
   never FAIL. Current flags (real, heuristic):
   - `apps/api/src/sso.test.ts` — asserts omitted-branch
     (`missingOrInvalid`/SESSION_SECRET) only; no echoed/redacted assertion.
   - `apps/api/src/config.test.ts` — same shape.
   Court flip: single-branch secret-test fixture → G4 WARN emitted, exit 0.
   Witnessed.

## Non-vacuity

`bash scripts/convention_gates.sh --court` injects one violation of each type
(G1/G3/G4 on temp-copy roots, G2 via a shim generator on a temp root) and
requires every gate to flip; a gate that cannot flip exits 1 as a vacuous
gate. Latest run: all four FLIP witnessed, COURT-EXIT=0.

## Receipts

- `just convention-gates` → exit 0, `CONVENTION-GATES SUMMARY: fail=0 warn=2`
- `bash scripts/convention_gates.sh --court` → exit 0, 4× FLIP witnessed
- G2 flip court: clean→0 / drift→1, pre-gate bytes restored sha256-exact

## Disclosures / session-introduced events

- **Court clobber of `receipts/INDEX.md` (mid-development, since restored)**:
  an early G2 court draft ran the fixture generator with the real repo as cwd;
  the relative write overwrote the real INDEX.md with fixture content. That
  copy of INDEX.md had been produced by `receipts_index.sh --emit-index` at
  13:48Z (regenerated after real drift was caught when `gaps/68-deletion-safety.md`
  landed — the gate catching genuine GENERATED-file staleness); restored from
  that 13:48Z byte copy, then the estate moved to SMALT_ROOT and G2 degraded to
  loud SKIP. Whoever restores the local generator should re-emit INDEX first.
- **Fixed violations: 0 in code.** No one-line violations needed fixing; the
  only real G2 FAIL during the lane was genuine staleness (new gap file
  landed), resolved by the canonical `--emit-index`, not a code edit.
- **Concurrent-lane churn**: this lane ran on the shared checkout while other
  lanes moved the posh estate to `SMALT_ROOT`, added/removed `gaps/` files,
  and rewrote the justfile. G3's checked-line count and G2's availability
  vary with that churn by design (loud skip / real counts, never silent).
- Lane brief named smalt-repo surfaces (`justfile.d/5*.sh`, `posh-regen-check`,
  adapter `.go`, `lib/smalt/posh/pipeline`) that do not exist in
  courtroom-platform-az; each gate was adapted to this repo's nearest analog
  (see table above). `posh-regen-check`'s missing pipeline leg has no
  counterpart here — G2 covers the only GENERATED artifact in this tree
  (`receipts/INDEX.md`).
