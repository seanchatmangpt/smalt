# BK-68 — witness standing-line backfill (mechanical hygiene pass over v26.10.21 receipts)

**Standing:** ALIVE
Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt (branch main, uncommitted)
Follows: BK-67 census (`docs/jira/v26.10.22/receipts/bk67-witness-census.md`)

## What was done

Mechanical, formatting-only backfill of the 60 receipts BK-67's dry-run classified
WITNESS-FAIL / NO-STANDING in `docs/jira/v26.10.21/receipts/`. Root cause re-derived:
the gate regex (`scripts/witness_all.py` STANDING_RE:
`^\s*(?:\*\*)?Standing(?:\*\*)?\s*[:=]\s*(.+)$`) is defeated by a leading `- ` on a
list-item standing line — the corpus's dominant malformation (44 of 60). Every flagged
receipt already carried real embedded output; none needed content repair.

Two fix shapes:

1. **De-dash (44 receipts)**: removed the leading `- ` from the first standing-line
   only (e.g. `- **Standing**: ALIVE` → `**Standing**: ALIVE`). The rest of any list
   the line belonged to is untouched.
2. **Insert (16 receipts)**: no parseable standing line existed; typed the receipt's
   true standing from its own body (verdict sections re-read, never invented) and
   inserted a canonical `**Standing:** <TOKEN>` line near the top. Dispositions:
   armstrong-idiom-census=PARTIAL_ALIVE (census with typed findings),
   bench5-powl-pipeline=ALIVE ("Standing unchanged: ALIVE" in body),
   bench9-deletion-audit=PASS (no-op deletion verdict),
   cas412r-postfix-regression=PASS, ctxfill-receipt-flag-backfill=PASS,
   impl21-postupgrade-sdk=PASS, ja-r1-silent-violation-fixes=ALIVE,
   ja4-isolation-audit=PASS (post-fix re-witness), pb3-executor-ceiling=PASS
   (0 errors L64→L8192), phase1-capability-probes=PARTIAL_ALIVE,
   "powl2-high-findings-recourt"=PASS (both HIGHs CLOSED-WITH-RECEIPT/HOLD),
   sj4-journal-telemetry-wiring=ALIVE, sqld5-sql-shape-gen=ALIVE,
   t27lq-listqueues-paging-witness=ALIVE, val-nfr-migrate=PARTIAL_ALIVE (mixed table),
   val-prd=PARTIAL_ALIVE (mixed cells, one PENDING).

## Before / after

```
$ just witness-all-dry   # before
[WITNESS-SUMMARY] total=198 witnessed-green=0 stale-typed=86 failed=60 (DRY-RUN)
$ just witness-all-dry   # after
[WITNESS-SUMMARY] total=200 witnessed-green=0 stale-typed=125 failed=0 (DRY-RUN)
```

- NO-STANDING class: 60 → 0. Exit 0 both runs (dry-run never exits 1).
- total 198 → 200: two receipts landed from concurrent in-flight lanes during this
  pass (corpus grew; not part of this diff — verified my diff touches none of them,
  see Diff review below; ja15b was mid-edit by its owner lane).
- stale-typed 86 → 125: the 60 flipped from FAIL to STALE (no safe-class command —
  loud, lawful, non-blocking) plus concurrent-lane growth. STALE is not a failure
  class; it is the expected disposition for substrate/bench-class receipts.

## UNKNOWN-NEEDS-REWITNESS list

Empty. All 60 had real embedded output; every inserted token was typed from the
receipt's own verdict language. Zero fabricated standings; zero owner-dispatch items.

## Diff review (formatting-only proof)

Backup: `/tmp/bk68_backup/` (pre-edit snapshot of the whole receipts dir). Full-dir
diff confirms every changed line is a standing-line change:

- 44 de-dash edits: one line each, `- ` prefix removed, token + prose byte-identical.
- 16 inserts: one added `**Standing:** TOKEN` line each, nothing removed.
- The only non-standing diff lines in the tree belong to `ja15b-gap-adoption.md` —
  an in-flight lane's concurrent edit (JA-15b lane listed in-flight in BK-67), not
  part of this pass.

## Boundary

- Formatting pass only; findings/numbers byte-identical (verified by full-dir diff).
- No commit made (per dispatch).
- Full `witness-all` re-run remains wrap-lane-owned (BK-67 boundary carries: dirty
  tree with in-flight STORE/SPOF/SYNC/BK/W3C/JA lanes).
- Root-cause note for the gate owner: a regex tolerant of a list-item `- ` prefix
  would make this malformation class impossible; left to the owner, not patched here.
