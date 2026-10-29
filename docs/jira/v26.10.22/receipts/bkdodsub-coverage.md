# BK-DODSUB — PATTERN-LANGUAGE location reconciliation + docs-dod/kd-fence coverage of pattern docs

Standing: ALIVE (gates re-run green post-fix, outputs embedded). Context: solo.

## Finding 1: no duplicate exists — `patterns/` copy is the only and canonical one

Dispatch premise was two copies (milestone root + `patterns/`). Ground truth on
disk + git:

- `git ls-files docs/jira/v26.10.22/` shows the file tracked ONLY at
  `docs/jira/v26.10.22/patterns/PATTERN-LANGUAGE.md`.
- `git cat-file -e HEAD:docs/jira/v26.10.22/PATTERN-LANGUAGE.md` → "does not
  exist in HEAD"; worktree root copy absent (`ls` ENOENT).
- History: created at `patterns/` in 34491d17, extended 609e88d4, drift-refreshed
  at that same path by BK-PATDRIFT (89743beb, 106-line diff on
  `patterns/PATTERN-LANGUAGE.md`). No root copy ever survived to HEAD.

So BK-PATDRIFT edited exactly the tracked path; the root path is a phantom from
the dispatch premise (likely the `git log --all`-style path query resolving the
pre-move name). Nothing to delete, nothing cites a root path
(`grep -rn 'jira/v26.10.22/PATTERN-LANGUAGE'` over docs/ scripts/ justfile.d/
gates/ — zero matches). Diff: zero files for this step.

## Finding 2: the fence skipped the pattern docs — fence extended

Pre-fix: `kd_receipt_fence.py` scanned only `docs/jira/*/KNOWN_DIVERGENCES.md`
(318 cites). `docs/jira/v26.10.22/patterns/PATTERN-LANGUAGE.md` cites 4 receipt
paths, `docs/jira/v26.10.22/BROWSER-COURT-PATTERNS.md` cites 3 — all invisible
to the gate.

Minimal diff to `scripts/kd_receipt_fence.py`:

- new `pattern_docs(root)` glob: `docs/jira/*/patterns/*.md` +
  `docs/jira/*/BROWSER-COURT-PATTERNS.md`
- new scan loop (plain receipt-cite existence, no ROW_RE/INFLIGHT semantics —
  those are KD-row-specific)
- bare-path resolution: inside a `patterns/` subdir, bare `receipts/...` cites
  resolve milestone-root-relative (same convention as the KD register), i.e.
  `doc_dir = parent if parent.name != "patterns" else parent.parent`

Non-vacuity: the first post-edit run FAILED (rc=1) with 4 MISS lines because the
initial bare-path resolution was subdir-relative — the extended fence demonstrably
can refuse. After the resolution fix:

```
kd-receipt-fence: checked 325 receipt cites across 6 registers + 2 pattern docs -> OK
rc=0
```

(318 KD-register cites + 7 pattern-doc cites.)

## Finding 3: gates green post-fix

```
$ just docs-dod-check   (post-fix)
rc=0
OK    ... 61 OK lines
kd-receipt-fence: checked 325 receipt cites across 6 registers + 2 pattern docs -> OK
```

Pre-fix baseline (both rc=0 but blind to the subdir): fence "checked 318 receipt
cites across 6 registers -> OK"; docs-dod-check rc=0.

## Files

- `scripts/kd_receipt_fence.py` (fence extension, minimal diff)
- `docs/jira/v26.10.22/receipts/bkdodsub-coverage.md` (this receipt)

PATTERN-LANGUAGE layout unchanged (single canonical copy at `patterns/`).
