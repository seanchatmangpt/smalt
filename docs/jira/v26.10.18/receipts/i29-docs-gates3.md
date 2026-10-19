# i29 docs gates 3 — post-d1298be receipt-index / docs-dod-check / naming-sweep

Context: solo(docs gates leg; receipt-index sanctioned regen; no lib/ edits)

- Date: 2026-10-18, repo /Users/sac/smalt @ main d1298be (no git commands run beyond status-free checks).
- Scope: post-d1298be docs gates only.

## Actions

1. `just receipt-index` (sanctioned regen) — wrote
   `docs/jira/v26.10.14|16|17|18/RECEIPTS.md` + `receipts/INDEX.md` (4 windows, exit 0).
2. NO-CONTEXT placement fixes: 12 receipts had a Context phrase embedded
   mid-line (list-bullet `"- Context: ..."` or fused into a Date/Standing
   line), which fails the tool's `^Context:\s*(solo|pair\(|slice\(|full)`
   regex. Inserted a standalone `Context: ...` line after each H1
   (content preserved verbatim from the existing phrase):
   i29-capabilities-drift, i29-capabilities-drift2, i29-colima-stop-runbook,
   i29-court-dry1, i29-doctor-dod-gapcensus, i29-eh-shim-audit,
   i29-push-readiness2, i29-scratch-sweep, i29-sdk-smoke-deps, i29-wire-fresh2,
   i29-a22f1-witness, i29-ws-cli-fresh.
3. `i29-docker-reclaim.md` (standing UNKNOWN SUSPECT) left untouched per
   dispatch — honest flag.
4. `just docs-dod-check` — exit 0, all 62 paths OK (output below).
5. `just naming-sweep` — `[NAMING-SWEEP] PASS: 0 violations / 47 allowed`.

## Verification (real output)

- receipt-index regen output: `wrote .../v26.10.14|16|17|18/RECEIPTS.md` +
  `receipts/INDEX.md`, exit 0.
- v26.10.18 flag counts after regen (grep -c on RECEIPTS.md):
  `NO-CONTEXT` = **0**, table `SUSPECT` rows = **1**
  (`i29-docker-reclaim.md`, standing UNKNOWN — honest, retained).
  Window-level SUSPECT listing shows exactly that one receipt.
- docs-dod-check: `DOD_EXIT=0`, final path `OK    README.md`, zero MISS lines.
- naming-sweep: `[NAMING-SWEEP] PASS: 0 violations / 47 allowed`, exit 0.
- New-receipt index check: grep for each of
  i29-capabilities-drift2 / i29-checkpoint2 / i29-eh-shim-audit /
  i29-scratch-sweep / i29-push-readiness2 / i29-midnight-map-refresh /
  i29-court-dry1 / i29-g5-injectors / i29-push-readiness in
  `docs/jira/v26.10.18/RECEIPTS.md` — all present.
  `i29-court-dry2/3` do not exist on disk (only dry1); nothing to index.

## Standing

- Standing: PASS (docs gates green: receipt-index 0 NO-CONTEXT / 1 honest SUSPECT,
docs-dod-check exit 0, naming-sweep 0 violations)
