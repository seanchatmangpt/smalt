# BK-125 — SYNC-3 reconciliation (ghost-lane reap)

**Standing**: ALIVE
- Context: solo
- **Date**: 2026-10-22
- **Claim reconciled**: fleet ledgers listed SYNC-3 as in-flight/UNWITNESSED, but SYNC-3's
  deliverable was landed under its alias lane ATH-3 (law files + GLD-7-class law court).

## 1. Landed deliverables verified on disk (2026-10-22)

```
$ ls -la docs/jira/v26.10.22/receipts/ath3-law-court.md docs/jira/v26.10.22/law/ test/integration/ath3_law_court.exs
-rw-r--r--@ 1 sac  staff  8757 Oct 21 23:46 docs/jira/v26.10.22/receipts/ath3-law-court.md
-rw-r--r--@ 1 sac  staff  2294 Oct 21 21:41 docs/jira/v26.10.22/law/rules.n3
-rw-r--r--@ 1 sac  staff  4276 Oct 21 21:56 docs/jira/v26.10.22/law/shapes.ttl
-rw-r--@ 1 sac  staff  2661 Oct 21 20:49 docs/jira/v26.10.22/law/workflow.powl.ttl
-rw-r--r--@ 1 sac  staff 24428 Oct 21 21:22 test/integration/ath3_law_court.exs
```

Receipt `ath3-law-court.md` head: `**Standing**: ALIVE`, `Context: solo`, 2026-10-21,
`MIX_BUILD_ROOT=_build-ath3`, exit 0, 44 `ok` assertions, 0 failures, two consecutive
green runs, embedded command output present. Charter's gate ("law swap does not touch a
single substrate line") honored: the receipt states the law files were the ONLY
domain-aware artifacts, no `lib/` or `workspace/` file touched.

Naming delta vs charter (honest variance, not a gap): charter named `law/shacl.ttl`,
`law/n3`, `law/powl.ttl`; landed files are `law/shapes.ttl`, `law/rules.n3`,
`law/workflow.powl.ttl`. Same three law artifacts, different filenames.

## 2. Ledger corrections (docs/jira/v26.10.21/_LANES.md)

Two UNWITNESSED rows listed `SYNC-1, SYNC-3` together; SYNC-3 split out of both:

- v7.2 UNWITNESSED section: `| SYNC-1, SYNC-3 | UNWITNESSED | ... |` →
  `SYNC-1` stays UNWITNESSED; `SYNC-3 (= ATH-3)` → ALIVE, evidence
  `../v26.10.22/receipts/ath3-law-court.md`.
- v7.3 UNWITNESSED section: same split; SYNC-1 keeps its original evidence text
  (SYNC-2 charter-only note).

The v7.3 fold already cited `ath3-law-court.md` in its ATH-1 row — the ghost was the
SYNC-3 row not pointing at it, not a missing registration.

## 3. Ghost sweep (grep `SYNC-3` across docs/jira)

Full grep hit set (2026-10-22):

| File | Nature | Action |
|---|---|---|
| `v26.10.21/_LANES.md` (2 rows) | stale UNWITNESSED rows | corrected (section 2) |
| `v26.10.22/SYNC-CHARTER.md:42` | the charter row itself | authoritative, left as-is |
| `v26.10.22/receipts/bk81-lanes-v73.md:21` | historical receipt listing SYNC-3 among UNWITNESSED at its fold time | left as-is — receipts are immutable; it was true at write time |

No distinct SYNC-3 deliverable was chartered anywhere: SYNC-3 appears only in the
SYNC-CHARTER and the lane ledgers, and the charter's SYNC-3 deliverable is exactly what
ATH-3 landed (law files + GLD-7-class court). No gap to own beyond the filename variance
in section 1. SYNC-1 and SYNC-2 remain genuinely UNWITNESSED and are untouched by this
reconciliation.

## Commands

- `ls -la` on the four deliverable paths (section 1, verbatim output above)
- `grep -rn "SYNC-3" docs/jira --include="*.md"` (section 3 table)
- Edits: two-row split in `docs/jira/v26.10.21/_LANES.md`; this receipt. Nothing committed.
