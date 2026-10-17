# Receipt — AUD-5 wire-parity consolidation

Lane AUD-5, 2026-10-15, /Users/sac/smalt @ main (HEAD fd9cfea, dirty tree).
No lib/ edits, no commits, no KD filings by this lane.

## Subject
- docs/audit/SDK_SURFACE_PARITY_AUDIT.md — parity matrix + merged 36-entry gap
  inventory + census witness (co-edited in flight with a concurrent
  consolidation writer on the same checkout; final merge resolved row/status
  alignment and unified GAP-01..36 numbering, this lane re-aligned the Status
  column to the W-8 ledger)
- scripts/audit_surface_census.sh — deterministic verifier
- docs/audit/census_table.tsv — 77 SDK wire templates (AUD-1 + AUD-3 HTTP
  surfaces)

## Inputs (as-read from the section files, 21:19-21:35 PDT)
- aud1: 51 signatures — FULL 19 / PARTIAL 8 / MISSING 24 (10 mis-route class)
- aud2: 67 rows — FULL 40 / PARTIAL 11 / MISSING-UNREGISTERED 15 /
  UNSUPPORTED-REGISTERED 1 (KD-47)
- aud3: 28 signatures — FULL 14 / PARTIAL 3 / MISSING 10 /
  UNSUPPORTED-REGISTERED 1 (+1 N/A deployment-ops row)
- aud4: 24 rows — FULL 7 / PARTIAL 2 / DIVERGENCE 6 / MISSING 9

## Parity (per-service recomputed from section tables — doc §1)
Per-service: blob 32% (13/41), cosmos 55% (12/22), EH AMQP 77% (17/22),
SB $management 42% (5/12), SB $cbs 100% (6/6), SB locks 86% (6/7),
KV 30% (6/20), ARM 50% (14/28), Sentinel 50% (1/2), Resource Graph 55%
(6/11), APIM 0%, Cognitive Search 0%, Purview family UNKNOWN (5 mounted
routes verified). Lane-level: AUD-1 19/51, AUD-2 40/67, AUD-3 14/28,
AUD-4 7/24. Overall ≈ 51% (91 FULL of 178 audited signatures).

## New-gap count
36-entry inventory: 29 cross-marked to registered KD rows (KD-02/05/12/13/16/
33/47/54..75), 7 NEW (GAP-30..36 = AUD-4: Sentinel batch query, RG
resultFormat/facets/managementGroups, APIM, Cognitive Search, Purview Atlas
v2 family) — pending KD registration. No KD rows filed by this lane.

## Census witness (scripts/audit_surface_census.sh, final state)
Run 2026-10-15 21:55 PDT:
== smalt registered routes: 116 ==
mapped=62 (incl 2 MISROUTE-MAPPED: blob comp-absorb KD-60; change feed KD-63)
registered-gaps=15 (KD-31/32/55..59/60/62/63/65 x2 + tags-at-scope typed refusal)
unregistered=0 -> CENSUS PASS, exit 0
Anti-vacuity: the pre-registration baseline run (21:33, 16 unregistered,
exit 1) witnesses the gate failing; reverting the TSV tokens to AUD1-xx
reproduces FAIL.

## Concurrency disclosure (same-checkout fan-out)
Three writers touched the consolidation seam while this lane ran: (1) this
lane (TSV + verifier + inventory v1), (2) a second consolidation writer
(recomputed matrix, renumbered GAP-01..36, own census script draft whose
registration check was vacuous — GAP tokens "registered" by mere mention in
the audit doc; superseded by the KD-ledger-only gate), (3) lane W-8
(KD-54..75 filed from the audit GAP blocks mid-flight). Resolution: one
script (KD-ledger-only registration), one numbering (GAP-01..36), Status
column re-aligned per-row to the ledger; misaligned cells corrected this pass.

## Verification ladder
- section files read from disk; KD cross-marks re-grepped at use time
- census run to PASS (exit 0) with a witnessed FAIL baseline (anti-vacuity pair)
- per-row status alignment printed and checked after the final edit (36/36)

## Standing
ALIVE (consolidation-level). Not adjudicated: aud4's SDK-absent surfaces
(APIM/Search/Purview cite absence, not wire witnesses). Falsifier: re-run
`scripts/audit_surface_census.sh` — must reproduce PASS/exit 0; any new
unmapped SDK template without a KD row re-fails it.
