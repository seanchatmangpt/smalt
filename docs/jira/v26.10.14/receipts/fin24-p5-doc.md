# fin24-p5 — superfans WO doc recovery

- **Date:** 2026-10-15
- **Lane:** P-5 doc recovery (fin24)
- **Status:** ALIVE
- **Subject:** docs/jira/v26.10.15/05-superfans.md (recovered from lane output)

## O

- Source: `/private/tmp/claude-501/-Users-sac-smalt/05be59f2-7268-42f6-8444-0ef4aaeee46d/tasks/aeec5a8825de2280b.output` — 43-line JSONL transcript; final assistant message (line 43, 31,078 bytes) contains 6+ degraded restarts of the doc concatenated.
- Last complete clean rendering starts at byte offset 21983 of that message and runs to EOF (9,095 bytes, 107 lines). Earlier restarts were truncated or garbled (one stub of 312 bytes; one with a duplicated `## 0. Summary`).

## μ (diff)

- Extracted final segment, wrote to `/Users/sac/smalt/docs/jira/v26.10.15/05-superfans.md`. No hand-editing of content — byte-exact slice of the transcript's final rendering.

## R (receipt / verification output)

- `leak-phrase count ("The leaked substrate lock took")`: **0** in extracted doc — see Standing note.
- Doc titles (`# 05 —`): 1 (no duplicated sections).
- Sections: Summary / Witnessed problem / Design (3 pollers: 15 s, 30 s, 20 s) / Falsifier / Acceptance / Files owned — all present exactly once.
- Table rows: 17; all pipe-delimited rows well-formed (≥3 pipes each).
- 107 lines, 9,095 bytes on disk.

## Standing

ALIVE for the recovery itself. One divergence from the dispatch spec: the literal sanity phrase "The leaked substrate lock took" appears **zero** times in the final clean rendering — that phrasing exists only in the earlier degenerated restarts (4 occurrences across the concatenated transcript). The final version restates it as "The 27-minute leaked-lock incident is a **detection-latency defect**…" (Summary §1 and Design §2.1, "the 27-min/4-report incident"). The integrity goal the phrase check targets (no duplication across restarts) is met: exactly one doc, one title, no garbled fragments.

## Falsifier

- A duplicated or garbled section in `docs/jira/v26.10.15/05-superfans.md` would refute the extraction.

## Files owned

- `docs/jira/v26.10.15/05-superfans.md` (created)
- `docs/jira/v26.10.14/receipts/fin24-p5-doc.md` (this receipt)

No commits made.
