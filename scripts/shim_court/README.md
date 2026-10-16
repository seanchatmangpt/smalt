# shim_court — reusable non-vacuity courts (lane S-6, v26.10.14)

Generalizes `scripts/mutation_court.py` (BEFORE / shim / AFTER / restore,
sha256-verified byte-exact restore) into a shell harness so any subject file
can get a non-vacuity court without rewriting the protocol.

## The BEFORE/AFTER/restore contract

A shim court proves a gate/behavior is **non-vacuous**: the witness command
actually changes outcome when the subject's behavior is replaced. Phases,
run by `with_shim <file> <before-cmd> <after-cmd>` from `lib.sh`:

1. **BASELINE** — sha256 the subject file. Missing file → `[FAIL:BASELINE]`,
   exit 1.
2. **BEFORE** — run `<before-cmd>` against the *unmodified* file. It must
   exit 0 (the OLD signature holds). Otherwise `[FAIL:BEFORE]`; the court
   refuses to shim and exits 1 with the file untouched.
3. **SHIM** — call the court-defined `apply_shim` (must edit the subject in
   place and mark every edit with the literal string `SHIM-COURT`). Backup
   taken first; on hook failure or missing marker the file is restored and
   `[FAIL:SHIM]` exits 1.
4. **AFTER** — run `<after-cmd>` against the *shimmed* file. It must exit 0
   (the NEW outcome holds under the shim). This flip is the non-vacuity
   proof. On failure the file is restored+verified first, then
   `[FAIL:AFTER]` exits 1.
5. **RESTORE** — restore from backup; sha256 must equal the baseline
   byte-exact or `[FAIL:RESTORE]` exits 1 (fail-closed; the subject is
   reported CORRUPTED). An interrupt mid-AFTER also attempts restore.

Exit codes: `0` all phases passed; `1` typed FAIL (see
`[FAIL:PHASE]` lines); `3` loud SKIP via `shim_court_skip "reason"`.

## Writing a court

```bash
#!/usr/bin/env bash
# scripts/shim_court/<name>_court.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Optional: a leg needing a missing environment skips loudly, never fakes:
# [ -x "$(command -v docker)" ] || shim_court_skip "docker not installed"

apply_shim() {
    # Edit $SHIM_FILE in place; mark with SHIM-COURT.
    printf '# SHIM-COURT: gate bypass, temporary, restored+verified\n' \
        > "$SHIM_FILE"
}

shim_court_self_check   # prove the sha256 restore rule detects corruption

with_shim \
    path/to/subject.ex \
    '<cmd> expecting the OLD behavior; exit 0 if observed' \
    '<cmd> expecting the NEW behavior under the shim; exit 0 if observed'
```

## Rules

- **sha256 rule**: the subject is restored byte-exact or the court FAILS —
  a mismatch is never a pass and is reported as corruption.
- **SKIP-loud**: a leg requiring a missing environment calls
  `shim_court_skip "reason"` (exit 3). An aggregate records SKIP/BLOCKED,
  never PASS. Faking a pass is banned.
- **Marker**: shimmed content must contain `SHIM-COURT`; the lib refuses a
  shim that forgot it (prevents silently mutating without disclosure).
- **No git operations**; transient mutation is backed up to `$TMPDIR` and
  restored in the same process.
- **Never a vacuous pass**: if BEFORE and AFTER witnesses would both pass
  regardless of the shim, the court is vacuous — pick a witness that flips.

## Running

```sh
just shim-court arm          # one court; lists available names if unknown
just shim-courts             # aggregate: run all present courts, summarize
```
