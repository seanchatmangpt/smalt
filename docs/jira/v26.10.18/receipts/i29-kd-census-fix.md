# i29 — KD register census prose fix

Standing: PASS (prose-only edit; no table row touched, no flips, no git)

Context: solo (single lane, one file scope:
docs/jira/v26.10.14/KNOWN_DIVERGENCES.md Census section only)

## Command (real output)

    $ grep -c '^| KD-' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
    95

    $ python3 -c "rows=[l for l in open('docs/jira/v26.10.14/KNOWN_DIVERGENCES.md') if l.startswith('| KD-')];print(sum(1 for l in rows if l.strip().strip('|').split('|')[-1].strip().startswith('OPEN')))"
    55

    $ git diff --stat docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
     docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | 12 +++++++++++-
     1 file changed, 11 insertions(+), 1 deletion(-)

    $ git diff docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | grep -c '^[+-]| KD-'
    0

## Change

Census section (line ~164): appended a table-derived recount entry after the
2026-10-17 kd_flip note, correcting the drifted prose. Correction states
**95 rows, KD-01..KD-97, no duplicate ids — 55 OPEN-class / 40 closed-class**
with both replay commands embedded verbatim (grep -c '^| KD-' → 95; python
status-cell OPEN-prefix count → 55), so the next auditor replays them
mechanically. The prior prose history ("88 rows / 60 OPEN-class", etc.) is
explicitly labeled historical in the correction entry; the running log lines
were left intact per the historical-record discipline.

No row edited: `git diff | grep -c '^[+-]| KD-'` = 0 (verified above).
Verification replay after edit: 95 total, 55 OPEN — counts match the
registered correction.
