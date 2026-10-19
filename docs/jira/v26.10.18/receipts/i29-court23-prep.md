# i29 — AZB-23 gate executor pre-positioned (court23.sh)

Standing: PARTIAL_ALIVE (executor ready, not yet executed — quiet window not open, colima up)
Context: solo(azb-23-prep, no concurrent lanes on scripts/ or receipts/i29-*)

## What landed

- `scripts/court23.sh` (executable, one-shot, NOT executed): AZB-23 gate executor.
  1. `just quiet-check` must exit 0, else typed `REFUSED: quiet-check failed` exit 1.
  2. `just court-x2`, full log captured to `tmp/court-x2-<epoch>.log`.
  3. Parses court_x2.sh's own markers (`Run N summary line: ... GREEN|NOT GREEN`,
     failure-set sections) and appends a summary (two verdicts + failure-set diff
     when run1 != run2) to `docs/jira/v26.10.18/receipts/i29-court-x2-final.md`.
  - `DRY_RUN=1` echoes commands and appends a clearly-marked DRY-RUN row (no gates run).

## Verification (dry path only — executor deliberately NOT run)

```
$ bash -n scripts/court23.sh
SYNTAX-OK
$ DRY_RUN=1 bash scripts/court23.sh; echo "exit=$?"
== AZB-23 gate @ 1792392880 ==
[DRY_RUN] just quiet-check
[DRY_RUN] just court-x2 >tmp/court-x2-1792392880.log 2>&1
[court23] summary appended to docs/jira/v26.10.18/receipts/i29-court-x2-final.md
exit=0
```

One real defect found and fixed during dry-path testing: the markdown fence
lines were written as `echo "\`\`\`"` (double-quoted backticks), which bash
treated as open command substitution — witness `command not found: $'\n echo
1792392870'` on the first dry run. Fixed to single-quoted `echo '```'`;
re-run clean. The polluted DRY_RUN test blocks were removed from
`i29-court-x2-final.md` (file now empty; the executor creates content fresh).

Verdict parsing is anchored to `scripts/court_x2.sh`'s actual output markers
(read on disk: lines 64-99), not guessed formats.

## Not done / falsifier

- The real gate has NOT been executed (colima up; quiet window closed).
- Falsifier for the executor itself: when the quiet window opens,
  `bash scripts/court23.sh` must refuse under a failing quiet-check, produce
  `tmp/court-x2-<epoch>.log`, and append a real-verdict summary; a run that
  appends DRY-RUN text or skips the log capture is a FAIL.
