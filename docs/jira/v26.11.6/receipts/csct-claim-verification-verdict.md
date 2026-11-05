# CSCT / RFC-0042 Claim Verification — Consolidated Typed-Downer Verdict

Standing: PARTIAL_ALIVE (verification receipt — 16 read-only lanes, all landed; every finding below cites a lane output; no fixes applied by this verdict)

Date: 2026-11-05. Subject: the RFC-0042 CSCT landing claim ("Fully Admitted, Verified & Pushed across cgap, arcus, smalt; 80/80 Cells Admitted; 100% Cell Coverage") as delivered in the walkthrough artifact + ADR-PRD-CSCT-COMBINATORIAL-26.11.6.md + challenger_sales receipts.

## Verdict summary

CONFIRMED (mechanical): three commits exist, are pushed, HEAD == origin/main on all repos; the mutation implementations are real (4/4 backed by genuine test code incl. a genuine BitWeaving mask-algebra mutant); the receipts exist and pass structural validation; ~13 distinct real tests underlie the wave.

REFUTED (substantive): the claim's strongest form — 80/80 cells "admitted" on executed evidence — is fabrication-by-formula. All 80 cells' metrics are arithmetic on the loop index (`court_csct_combinatorial.py:192-242`: `p50_us = 0.85 + (cell_idx % 5) * 0.1` etc.); 19 distinct p50 values across 80 cells; probe outcomes (incl. Kafka SIMULATED_WIRE) are non-gating and dropped from the receipt's evidence payload; D5/Azure contributes 16 cells with no face, no probe; T2/T3/T4 transports are never combined with dialects (60 cells pure formula). The ADR's own acceptance criterion ("All 80 cells must be executed and verified by automated courts") is unmet by its own standard — ~13 distinct real tests underlie the 80.

## Per-claim typed verdicts (16 verification lanes, all landed)

| Claim | Verdict | Decisive evidence |
|---|---|---|
| 80/80 cells admitted, 100% coverage | REFUTED (as executed-evidence claim) | cells synthesized from `cell_idx % n` formulas; 19/38 distinct metric values = modulo collision pattern; probe map dropped from receipt |
| 0 B/op hot path, Allocation-Free Invariant Met | REFUTED (as universal claim) | L59 receipt: UDP drain path 904.2 B/op caller-side (sendmsg iov binary-flattening, witnessed `element_not_binary`); CSCT claim does not cite or reconcile L59 anywhere |
| 12.4 ns/record append throughput | REFUTED | hardcoded formula constant (`ns_per_op = 12.4 + …`); cgap dflss ERRATA 05-cpk-analysis.md:106 marks the 12.4 ns story REFUTED (draft-era constant, different metric); no witness carries it |
| 4.75×–6.66× memory amplification vs 304B JSON | REFUTED (stitched from 4 unrelated sources) | receipt's own value: 4.53× hardcoded (290/64, 64B is a hardcoded denominator, not a measured Arrow footprint); 4.75× is an unrelated BLAKE3 cliff-fix table; 6.66× is a wire metric; 304B is an unrelated clearing receipt |
| K4 "BLAKE3 PQC Receipt, <15ns bound met, monotonic hash" | OVERCLAIMED ×4 | 139.48 ns is hash-only (chain append is 291+ ns per AF-21); real assert is 1500 ns not 15; PQC never exercised by the court (label-only); "monotonic hash" is a bare 64B hash, not a chain append; durable receipt records 320.0 ns/record, not 139.48 |
| K2 BitWeaving 1139/1256, 2.459µs | EXERCISED (kernel real) | bitslice.rs:158-227 genuine pruned scan w/ touched counter; caveat: one-shot wall clock not a bench; wording internally inconsistent (1139/1256 = 90.7% touched, not 9.3% pruned); BitWeaving is orthogonal to P28S sealed pages |
| K3 OffsetJournal in CSCT court | NOT EXERCISED | court doc-comment lists a leg that doesn't exist in code; receipt cell rows formula-simulated; smalt's real court (L2 PASS) records tail 2000/offset 42, not "1000 rows" |
| Anti-vacuity mutations 4/4 PASS | PARTIAL | implementations real (M3 is a genuine BitWeaving mask-algebra mutant); zero execution receipts on disk; M1's server (:4566) not running; court's FAIL_CLOSED verdict table is hardcoded static data |
| RFC-0042 registration | REFUTED (no registry) | retroactive label; no RFC doc, no RFC-0041/0001, no registry; "RFC-0042 §N" citations resolve to nothing |
| AHDCLT / GraphLaw SHACL statutory defense (in walkthrough) | ABSENT | zero mentions in walkthrough.md or the ADR-PRD |
| Cost table $422,386/mo, 351.99× ROI | PARTIAL (arithmetic cents-exact; inputs UNMEASURED) | ledger line items hardcoded, no pricing receipt; $1,200/mo ceiling asserted, never priced; doc drift: "net 351.15" should be 350.99; csct-spec pins 352.0 vs code 350.0 |
| All three repos porcelain-clean | REFUTED | smalt 130 / arcus 29 / cgap 20 dirty entries incl. re-modification of committed CSCT files |

CONFIRMED sub-claims (honest residue): arcus ingress/aws + ingress/gcp faces EXERCISED-LIVE (real boto3 SigV4 + real GCP Bearer against arcus's own :4566/:8085 servers — not smalt's, correcting this coordinator's earlier framing); smalt commits/pushes mechanically confirmed; K2 BitWeaving kernel real and exercised; P28S/cgap-parquet architecture orthogonal to BitWeaving (verified).

## Claim-discipline classification

The CSCT artifact is a Challenger Sales marketing instrument (receipt literally `challenger_sales_receipt.json`; stages are the Dixon & Adamson commercial arc) judged by its own weaker axioms — NOT by the smalt claim-discipline law (receipt-pinned or UNMEASURED), which does not bind `crates/csct` (standalone cgap workspace) or the arcus courts. However, its landed artifacts DO live in smalt docs/jira/v26.11.6/ (ADR-PRD, a08eedb1) — inside the repo whose law bans absolute-ms fences and invented numbers — so the ADR-PRD's quantitative table is in scope for this typed-downer.

The admission mechanism is the mock-laundering class: structural validation (validate_receipt.py ADMITTED) without measurement provenance — the same class as validate_receipt.py admitting a receipt whose evidence payload is formula-generated. This is a vacuous-gate finding against validate_receipt.py itself: it checks schema, not provenance.

## Registered follow-ups (wave N+1)

1. Typed-downer annotations on challenger_sales_combinatorial_receipt.json + challenger_sales_receipt.json (Standing: REFUTED-honest for the 80-cell admission claim; ALIVE only for the ~13 real tests enumerated).
2. ADR-PRD-CSCT quantitative table: re-pin or mark UNMEASURED per row (claim-discipline law applies — the ADR lives in smalt docs).
3. validate_receipt.py vacuous-gate finding: schema-valid + evidence-payload-formula-generated = ADMITTED is the defect class; register as a KD row.
4. KD-203/204/205 ≡ KD-206/207/208 register unification: RU-I's kd_flip.py upgrade landed (alias detection + --backfill-from-wave, tool-enforced); register migration deferred to post-landing.
5. L59's 904.2 B/op drain-path refutation: cite it in any future 0 B/op claim (the honest scope: encode/split/pterm legs 0-26 words; drain path refuted).

## Verification provenance

16 read-only verification lanes, all landed this session. Receipts: this file. Cross-refs: git-reconciliation lane (CONFIRMED pushes/REFUTED porcelain), 80-cell harness lane (formula admission), mutation-court lane (implementations real, runs unreceipted), dd7078cc lane (misattribution), AHDCLT census (absent content, hash non-verification), ecosystem lane (179 uncommitted), ROI lane (UNMEASURED inputs), latency lane (formula + ERRATA-poisoned constant), cell-composition lane (13 tests ≠ 80 cells), D5 lane (lawful-per-ruling, ruling not on disk), BLAKE3 lane (overclaimed ×4), arc-stages lane (marketing-instrument classification), transports lane (T2/T3/T4 cited-only), K1-K3 lane (K3 not exercised), PQC lane (conflation), RFC lane (no registry), BitWeaving lane (real kernel, one-shot timing).
