# CTXFILL-2 — v26.10.21 receipt flag close-out

**Standing**: PASS
- **Context**: solo
- **Date**: 2026-10-21
- **Repo**: /Users/sac/smalt

## Scope executed

1. **Context regex fix** (`scripts/receipt_index.py`): the detector required
   line-start `^Context:` and `pair\(`/`slice\(` (no space). Real receipts use
   `- **Context**:` bullets, mid-line `· Context: pair (…)` fields, and the
   `pair (` spaced form. New pattern:
   `\bContext\*?\**\s*:\s*\**\s*(solo|pair|slice|full)\b` (mid-line, markdown-tolerant,
   bare token accepted; the paren form remains valid). This alone de-flagged 11
   receipts that already carried law-form context in bullet/mid-line form.
2. **Context backfill**: 17 receipts appended a law-form `Context:` line
   (solo writer/court lanes; pair for skeptic/audit lanes: amqp10-skeptic-redispatch,
   bench10-skeptic, bench9-deletion-audit, gws14-skeptic, gws14-spec-scope).
   Total NO-CONTEXT closed = 28 (11 by regex fix + 17 by backfill).
3. **3 SUSPECT receipts** (bench5-powl-pipeline, gl9-governance-tax,
   gws2-wasm-build-trial): appended `## Integrity re-check (CTXFILL-2)` sections
   with fresh on-disk verification output (exit 0, real reads):
   - bench5: cited jsonl re-read — `bench5 5000 3222.3 0` matches headline
     (sha256 `45ba7e73…`); run log present (3 BENCH5 markers). ALIVE unchanged.
   - gl9: cited jsonl re-read — 3 rows, `234.19`/`281.42` reds/step match table.
     ALIVE unchanged.
   - gws2: pinned wasm artifact DRIFTED on disk (rebuilt Oct 21 17:02, sha
     `4dcb2421…` vs pinned `bb6d8419…`, 3 `duckdb` strings vs receipt's "zero") —
     disclosed, not silently reconciled. PARTIAL_ALIVE unchanged with drift typed.
4. **Generator date literal**: found and fixed — `main()` hardcoded
   `today = "2026-10-15"`; now `datetime.date.today().isoformat()`. Regenerated
   headers now read `Generated 2026-10-21`.

## Verification

```
$ just receipt-index   # tail
receipts=1067 sdk=61 total=1128 suspects=47   # 47 are pre-law windows, 0 in v26.10.21
$ grep "SUSPECT flags" docs/jira/v26.10.21/receipts/INDEX.md
- SUSPECT flags: 0 — none
$ grep -c "NO-CONTEXT" docs/jira/v26.10.21/receipts/INDEX.md
0
$ just docs-dod-check   # exit 0, all named receipt paths exist
```

## Standing

PASS — v26.10.21 flags 0/0 (NO-CONTEXT / SUSPECT); 47 remaining SUSPECT are
grandfathered pre-law receipts in older windows, out of scope. Exit 0 on
receipt-index + docs-dod-check.
