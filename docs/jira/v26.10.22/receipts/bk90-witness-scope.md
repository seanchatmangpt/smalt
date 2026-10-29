# BK-90 — witness_all scope fix: both receipt windows + asdf-exec class

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main, shared dirty checkout)
Authority: `docs/jira/v26.10.22/receipts/bk88-spof3-standing.md` (BK-88 gate-gap finding — this receipt closes it)

## Change

`scripts/witness_all.py` only:

1. **Scope fix**: `RECEIPTS_DIR` hardcoded to `docs/jira/v26.10.21/receipts`
   replaced by `discover_receipts_dirs()` — the two NEWEST
   `docs/jira/v*/receipts` dirs by mtime; explicit override via
   `WITNESS_RECEIPTS_DIRS` (os.pathsep-separated). BK-54's `GRAPHLAW_ROOT`
   override preserved unchanged.
2. **asdf-exec class**: `strip_env` now strips leading tool-manager wrappers
   (`asdf|mise|rtx exec`) before classification, so `asdf exec mix test …`
   — the corpus's dominant spelling and BK-88's finding — classifies as
   mix-test. Resolution still goes through `toolchain_env()` (asdf-pinned
   elixir/erlang prepended to PATH).
3. **Line continuations**: `join_continuations()` joins `\\\n` before
   extraction, so split commands classify as one command.
4. **Readonly pipelines**: a `readonly` command containing `|` is accepted
   only when every pipe segment's head is in READONLY_PREFIXES, and is run
   under a shell (previously the pipe was passed as literal `ls` args —
   `exit=1 ls: |: No such file or directory`).
5. Pipeline-segment shlex parsing wrapped (fail-closed "unparseable pipeline
   segment") — an unguarded `shlex.split` here crashed the full walk
   (ValueError: No escaped character, bench10-skeptic.md).

## Verification

- `just witness-all-dry`: exit 0.
  BEFORE (BK-88 receipt): `total=205 … stale-typed=127 failed=2` — v26.10.22
  receipts out of scope entirely.
  AFTER (as run, shared checkout grew during the lane):
  `[WITNESS-SUMMARY] total=244 witnessed-green=0 stale-typed=146 failed=4 (DRY-RUN)`,
  walk = 208 (v26.10.21) + 38 (v26.10.22) − 2 INDEX.md = 244. v26.10.22
  receipts appear in the classification (safe/STALE-typed, zero silent
  omits); the 4 `failed` are typed `NO-STANDING` receipts, loud in dry-run
  (gate exit 0 dry).
- Class histogram, v26.10.22 window only
  (`WITNESS_RECEIPTS_DIRS=…/v26.10.22/receipts --dry-run`, exit 0,
  total=36):
  safe-classified 7 = mix-test 3 (incl. one `asdf exec mix test` —
  spof3-affidavit-fixes.md), just 2, cargo-test 1, readonly 1;
  stale-typed 27; NO-STANDING 2 (ath3-law-court.md, bk73-workspace-combined.md
  — receipt content defects, loud and typed).
- Spot-run, 3 safe-class v26.10.22 receipts run FOR REAL
  (`WITNESS_RECEIPTS_DIRS=…/v26.10.22/receipts python3 scripts/witness_all.py --limit 3`),
  exit 0 (failed=2 are the NO-STANDING receipts, not spot-run failures):
  ```
  [WITNESS-SCOPE] windows=docs/jira/v26.10.22/receipts
  [WITNESS-GREEN] …/ath1-batch-frame-receiver.md exit=0  (mix-test)
  [WITNESS-GREEN] …/bk53-finalrelease-draft.md exit=0    (just docs-dod-check)
  [WITNESS-GREEN] …/bk81-lanes-v73.md exit=0 :: 208      (readonly ls|wc)
  ```
- The spot-run also exercises the `WITNESS_RECEIPTS_DIRS` override for real.

## Environment note (pre-existing, not introduced here)

Spot-run 1: `just docs-dod-check` failed with a just temp-dir IO error —
`$TMPDIR=/Users/sac/.cache/tmp` did not exist in the lane shell;
`mkdir -p` fixed it and the recipe passes. Ambient, not a witness_all
defect. bk81's `ls | wc -l` failure WAS a witness_all defect (readonly
pipes, fixed above).

## Standing

ALIVE — gate covers both active windows, asdf-exec class proven on the new
window by real rerun, zero silent omits (every non-safe receipt prints a
typed `[WITNESS-STALE]` or `[WITNESS-FAIL]` line).
