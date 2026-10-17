# Release-Flip Spec — smalt v26.10.16 (X10, docs-only)

Standing: PARTIAL_ALIVE — prepared pre-court-x2; applied ONLY after the
coordinator commits/tags. Do not apply now.

All edits reference on-disk state verified 2026-10-16.

## 1. CHANGELOG.md — UNRELEASED → released

File: `/Users/sac/smalt/CHANGELOG.md`. Current heading (verified on disk,
single occurrence):

```markdown
## [26.10.16] - 2026-10-16 — UNRELEASED
```

Flip diff:

```diff
-## [26.10.16] - 2026-10-16 — UNRELEASED
+## [26.10.16] - 2026-10-16
```

- Date stays 2026-10-16 (same-day release; do not invent a new date).
- The empty `## [Unreleased]` section above stays as-is (Keep-a-Changelog shape).
- Body sentence (verified on disk): "Status: pre-court-x2 — standing flips only
  on the two-green receipt (see `docs/jira/v26.10.16/FINAL.md`)." At flip,
  rewrite to match the run-8 outcome, e.g. on two-green:
  "Status: released 2026-10-16; two-green court-x2 receipt in
  `docs/jira/v26.10.16/FINAL.md`." If red/BUILD_BROKEN, the section heading
  flip is NOT applied and the Status sentence is replaced with the run-8
  verdict line verbatim.

## 2. RELEASE_NOTES standing line — both variants

File: `/Users/sac/smalt/docs/RELEASE_NOTES_v26.10.16.md`, lines 10-11
(verified on disk):

```markdown
Standing for this document: **PARTIAL_ALIVE pre-court-x2** — the
standing line flips only on the two-green receipt.
```

### Variant A — court-x2 two-green (run-8 PASS)

```markdown
Standing for this document: **ALIVE** — two-green court-x2 receipt landed
2026-10-16; see `docs/jira/v26.10.16/FINAL.md` court-x2 line.
```

### Variant B — court-x2 red or loud-skip (run-8 non-PASS)

```markdown
Standing for this document: **BUILD_BROKEN** — court-x2 run-8 verdict
"<VERDICT>" 2026-10-16 (quote the real verdict line verbatim from run-8
output); see `docs/jira/v26.10.16/FINAL.md` court-x2 line.
```

Applier quotes the actual run-8 verdict text; nothing in this spec may be
substituted for real output.

## 3. FINAL.md placeholder map (D11's) — verified current, on disk 2026-10-16

File: `/Users/sac/smalt/docs/jira/v26.10.16/FINAL.md`. All sites still carry
their unfilled placeholders; nothing has been filled ahead of the gates.

| Line | Placeholder | Filled by, at flip |
|---|---|---|
| 3 | `Standing: **PARTIAL_ALIVE** (pre-court-x2; standing line flips only on the two-green receipt).` | run-8 outcome (ALIVE / BUILD_BROKEN) |
| 5 | `court-x2: PENDING` | fin sweep, real run-8 verdict |
| 6 | `publish-dry: PENDING` | fin sweep, real `just publish-dry` result |
| 7 | `Commit SHAs: **PENDING-POST-COMMIT**` | fin sweep, post-wrap-commit hash + file count + push range |
| 18 | Tree-checksum line ("pre-court-x2 working tree") | fin sweep re-hash at wrapped tree |
| 19 | `court-x2 / publish-dry / commit SHAs: PENDING` summary line | fin sweep |

Verdict: the placeholder map is CURRENT — six sites, all correctly still
PENDING, no stale or premature fills.

## 4. Flip-time checklist — every doc that must change

1. `/Users/sac/smalt/CHANGELOG.md` — drop " — UNRELEASED" from the
   `## [26.10.16]` heading (§1); rewrite the Status sentence per run-8.
2. `/Users/sac/smalt/docs/RELEASE_NOTES_v26.10.16.md` — L10-11 standing line
   per §2 Variant A (two-green) or B (otherwise).
3. `/Users/sac/smalt/docs/jira/v26.10.16/FINAL.md` — six placeholder sites
   (§3): L3 standing, L5 court-x2, L6 publish-dry, L7 commit SHAs, L18
   checksums, L19 summary.
4. Generated artifacts — REGENERATE, never hand-edit:
   - `just receipt-index` → `docs/jira/v26.10.16/RECEIPTS.md` +
     `docs/jira/v26.10.16/receipts/INDEX.md`
   - `just bench-report` → `docs/jira/v26.10.16/BENCH_RESULTS.md`
   - `just sdk-matrix-md` → `docs/jira/v26.10.16/SDK_MATRIX.md`
   - `just gen-error-codes` (+ `--check` drift fence) → `docs/ERROR_CODES.md`
5. GAP tokens: at flip, `grep -n "GAP(" docs/WIRE_PARITY.md` — no GAP flips
   without a closing receipt; no new GAP tokens minted.
6. `/Users/sac/smalt/docs/jira/v26.10.16/NEXT_WINDOW.md` — re-check at flip
   that no line presents "pre-court-x2" as current standing (handoff pointer
   itself already names the next window).
7. Gates at the wrapped tree (inputs to the flip, not flip edits):
   `just court-x2` (run-8) and `just publish-dry` first; then `just
   docs-dod-check` must exit 0 after the doc edits land.
