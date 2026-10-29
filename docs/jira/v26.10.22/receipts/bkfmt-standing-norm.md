# BK-FMT — standing-line normalization sweep (v26.10.20–22 receipts)

**Standing:** PARTIAL_ALIVE
**Context:** solo

## Falsified premise, corrected at use time

BK-WRAP2 flagged `bkeplaw2-bench-fences.md` as not-indexed because of plain
`Standing:`. Re-derivation from `scripts/receipt_index.py` (line ~68,
`EXPLICIT_STANDING = r"^\s*[-*]?\s*\**\s*standing\s*:\**"`): plain `Standing:`
**is** extractor-matched. `bkeplaw2-bench-fences.md` was already indexed ALIVE
before this lane ran — its file was staged-uncommitted at the BK-WRAP2 read
(stale receipt). The real extractor-skip forms are:

1. `**Standing**:` (colon OUTSIDE the bold) — NOT matched by EXPLICIT_STANDING
   (`\**` before the colon cannot consume `Standing**:`), falls to generic
   status-word fallback. 128 files, including `bkwrap2-regen.md` itself.
2. No standing line at all — 126 files (see below).

## What was done

1. `bkeplaw2-bench-fences.md` line 3: `Standing: ALIVE` → `**Standing:** ALIVE`
   (content-preserving; evidence untouched).
2. Mechanical normalization over `docs/jira/v26.10.2*/receipts/*.md`: every
   line-anchored plain `Standing:` / `standing:` form rewritten to
   `**Standing:**` via
   `perl -pi -e 's/^(\s*(?:[-*]\s+)?)[Ss]tanding(\s*):/$1**Standing:**/'`
   applied to the 380 files that had a plain-colon standing line and no
   `**Standing` anywhere (list: /tmp/bkfmt-plain.txt, all `git ls-files`
   tracked). Applied only to files where the form was unambiguous; evidence
   bodies untouched. Post-check: 0 remaining plain-colon forms; 619 → 747
   files now carry the `**Standing` form.
3. No-standing receipts: NOT touched, no standings fabricated. 126 receipts
   across v26.10.20 (40), v26.10.21 (39), v26.10.22 (47) carry no
   `standing:`-col form at all. Typed **SUSPECT-PERMANENT (no-standing-line)**,
   owner = each receipt's original lane prefix (bk*/expl*/kd*/w6*/scvd*/gl*/
   impl*/ja*/az*/pat*/spof*/store*/val-*/ttv*/bench*/powl*/witness lanes) —
   disposition owed by window owners; full list re-derivable via:
   `for f in docs/jira/v26.10.2*/receipts/*.md; do grep -qiE 'standing[[:space:]]*:' "$f" || echo "$f"; done`
   (133 hits incl. 7 INDEX.md artifacts to exclude). A later wave (BK-100b
   "standing-backfill" class) may backfill from each receipt's own evidence;
   not done here — would be a content edit, not mechanical.
4. `python3 scripts/receipt_index.py` — exit 0.

## Before/after (receipt_index.py, embedded real output)

Before (pre-normalization, same session):
```
receipts=1376 sdk=61 total=1437 suspects=38
```
bkeplaw2 row (present BOTH before and after — the BK-WRAP2 claim was stale):
```
docs/jira/v26.10.22/RECEIPTS.md:126:
| bkeplaw2-ben | [bkeplaw2-bench-fences.md](receipts/bkeplaw2-bench-fences.md) | ALIVE | BK-EPLAW2 — fail-closed startup fences for bench harness self-boots |
```
After (post-normalization + this receipt):
```
receipts=1377 sdk=61 total=1438 suspects=38
```
Final (this receipt on disk, indexed — re-run):
```
receipts=1378 sdk=61 total=1439 suspects=38
```
Counts: 1376→1377→1378 receipts (+2 = this receipt + kd173r/other-lane receipt
that landed mid-lane), total 1437→1439,
suspects 43 (BK-WRAP2 as-of) → 38 at this lane's baseline → 38 after
(normalization was extraction-equivalent, as predicted). Idempotent on re-run.
Note: v26.10.22/receipts/ dir now holds 209 files; the indexer's regenerated
RECEIPTS.md/INDEX.md files were left uncommitted per lane scope (coordinator
regens/commits at wrap; generated artifacts, never hand-edited).

## Verification

- `grep -lriE '^[[:space:]]*[-*]?[[:space:]]*standing[[:space:]]*:'` filtered
  for no `**Standing` → 0 files remaining (was 380).
- `receipt_index.py` exit 0, before and after.
- All 380 normalized files confirmed tracked via `git ls-files` before edit.

## Falsifier

Re-run `python3 scripts/receipt_index.py`: exit 0, `suspects=38`,
`receipts=1377`. Any receipt later shown to have had its evidence body altered
by this lane falsifies the mechanical claim (diff scope is the standing line
only).
