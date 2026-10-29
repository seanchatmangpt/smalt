# BK-PRDA — second-pass skeptic over the PRD §4/§4a court matrix (18 cells)

**Standing: PARTIAL_ALIVE** — 17/18 cells disk-true; 1 typed reconciliation finding (owner: BK-PRDR).
Context: solo · Date: 2026-10-22 · Lane: BK-PRDA · Repo: /Users/sac/smalt (canonical checkout, read-only audit)

Scope: re-audit of `docs/jira/v26.10.22/PRD.md` §4 (12 rows) + §4a (6 rows) after
BK-PRDR's refresh and the BK-PPDOC/BK-NFRD1 NFR-row edits, cross-reconciled against
BK-ARD21's verdict table (`receipts/bkard21-terminal-audit.md`).

## 1. Per-cell verification (receipt exists + standing line matches cell claim)

All paths `[ -f ]`-verified this session, relative to `docs/jira/v26.10.22/`.

| Cell | Receipt(s) cited | On-disk standing line | Cell claim | Match |
|---|---|---|---|---|
| COURT-STORE-REPLAY | `../v26.10.21/receipts/ttv4-journal-boot-replay.md` | ALIVE | ALIVE — kill court 4/4 | YES |
| COURT-STORE-PART | `receipts/bk69r-store-reconciliation.md` (ALIVE), `receipts/store4-partition-court.md` (ALIVE, 4/4 ×3) | ALIVE / ALIVE | PARTIAL_ALIVE — TTV-5 named-file pairing open | YES |
| COURT-BOOT-REBIND | `receipts/bkvc-consolidated-courts.md` (ALIVE, green ×2), parent ttv4 (ALIVE) | ALIVE | ALIVE | YES |
| COURT-PRIVATE-TRIP | `receipts/bk50-private-trip.md` PARTIAL_ALIVE (honest RED, 41 hits) → `receipts/bk54-private-trip-remediation.md` ALIVE (GREEN) | PARTIAL_ALIVE → ALIVE | as claimed | YES |
| COURT-ATOM-CLAMP | `receipts/bkvc-consolidated-courts.md` + `receipts/bksec-nfr-closures.md` (PASS via composition) | ALIVE / PARTIAL_ALIVE | PASS (named court) | YES |
| COURT-CERT-OBS | bkvc (ALIVE), bksec (PARTIAL_ALIVE), `../v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` (PASS) | as above | ALIVE, D2 faces + cert-mint defect fix | YES |
| COURT-SYNC-FASTFWD/ANDON | falsifier greps embedded in bkvc receipt | — | UNBUILT (typed honestly) | YES (typed residue, not smoothed) |
| COURT-MERKLE-O1 | `../v26.10.21/receipts/pb4-merkle-dual-path.md` — see finding F1 | **REFUTED-as-noise** | PARTIAL_ALIVE | **MISMATCH → F1** |
| FR-SNC-001..004 | `receipts/ath1-batch-frame-receiver.md` ALIVE (11/11), `receipts/bk76-sync-auth-witness.md` ALIVE, `receipts/bk83-sync-e2e-auth.md` ALIVE (9/9) | ALIVE ×3 | ALIVE | YES |
| FR-RET-001..003 | `receipts/ath2-nextjs-client.md` ALIVE-browser/PARTIAL-sync, `receipts/bk63-sync-interop.md` ALIVE (9/9) | as claimed | PARTIAL_ALIVE | YES |
| FR-SVR-001 | `receipts/bk75-kd-final-census.md` | **PASS** | ALIVE — register spans KD-01..163+, census CLOSED | YES (PASS is terminal-census vocabulary; cell prose consistent) |
| FR-LAK-001..004 | `receipts/erl4r-vc-twins-lakehouse.md` | ALIVE (court 8/8 PASS, exit 0) | ALIVE | YES |
| COURT-WPS-SUBPROTO | `receipts/kd166-witness.md` ALIVE (falsifier, close condition NOT met) → `receipts/kd166-fix-witness.md` ALIVE (close met); faces az5/az5b ALIVE | as claimed | ALIVE | YES |
| COURT-MHSM-FAILCLOSED | `receipts/expl5r1-t1t2-repairs.md` ALIVE; `receipts/az4b-mhsm-receipt.md` ALIVE policy / typed UNSUPPORTED FIPS-hardware | as claimed | ALIVE | YES |
| COURT-KFK-RECCOUNT | `receipts/kafka-exp4-repairs.md` | ALIVE | ALIVE | YES |
| COURT-SAS-HOSTSCOPE | `receipts/kdsasv-audience-row.md` PARTIAL_ALIVE (registration) → `receipts/kd173r-audience-repair.md` ALIVE | as claimed | ALIVE — closed | YES |
| COURT-INGEST-HMAC | `receipts/bkbffsec-census.md` ALIVE; `receipts/expl7r1-bff-repairs.md` ALIVE | as claimed | ALIVE | YES |
| COURT-DEBUG-FACES | `receipts/bknenv-debug-faces.md` | ALIVE | ALIVE | YES |

Provenance receipt `receipts/bkprdr-prd-matrix.md` (ALIVE) exists. On-disk artifacts
`scripts/private_trip.py`, `justfile.d/51-bkvc.just`, `test/internal/expl5r1_court_test.exs` all present.

## 2. Court executions (cheap internal-tier registered courts, run this session)

- `scripts/fast_test.sh test/internal/bkvc_consolidated_court_test.exs` →
  `Result: 3 passed`, exit 0, wall 244s, build root `_build-ft-f5038861`. The receipt's
  `Result: 7 passed` is the combined `just bkvc-court` run (ttv4 integration 4/4 + internal 3);
  4+3=7 consistent — no divergence.
- `scripts/fast_test.sh test/internal/expl5r1_court_test.exs` →
  `Result: 8 passed`, exit 0, wall 272s, build root `_build-ft-5bdce099`.

Both registered courts green on the current tree — the cited receipts are replayable, not stale.

## 3. Cross-reconciliation with BK-ARD21's verdict table

BK-ARD21 audited v26.10.21's board (45 cells). Overlapping subjects with PRD §4:

- **AR-POWL-PB4 ↔ COURT-MERKLE-O1 = finding F1.** BK-ARD21 typed AR-POWL-PB4
  **TYPED-REFUTED (measured)** citing `receipts/pb4-merkle-dual-path.md` (standing
  REFUTED-as-noise: the O(n) fingerprint-gated sort variant is 1.45x slower; the
  current sorted-tuple path stands). PRD §4 COURT-MERKLE-O1 cites the same
  v26.10.21 receipt as its evidence for "PARTIAL_ALIVE — pb4 evidence exists" — a
  standing the receipt does not carry. The receipt that actually supports the O(1)
  receipt-size claims is `receipts/bkrsize-receipt-truth.md` (ALIVE; 320 B sync token
  re-measured, 48-word seal term resolved as a different surface than the 40-word
  claim) plus `receipts/pb4r-identity-court.md` (ALIVE — PB-4 harness exit 0,
  ground-truth court passes, 16 rows). Owner: **BK-PRDR** (matrix owner); the same
  citation sits in VALIDATION.md's COURT-MERKLE-O1 row. Next action: re-point the
  COURT-MERKLE-O1 cell to `receipts/pb4r-identity-court.md` + `receipts/bkrsize-receipt-truth.md`
  (both v26.10.22, both ALIVE), keep PARTIAL_ALIVE (named standalone court still pending).
- All other v26.10.21 rows BK-ARD21 typed (TTV-4/TTV-6/TTV-7b, JA-7, JA-R3, KD census,
  NFR-FOOTPRINT residual typing, BENCH-2/4/12 UNWITNESSED, DATA adoption residuals)
  are either outside §4's scope or agree with the §4/§4a cells — no second conflict found.
- BK-ARD21's D1/D2/D3 drift rows are closed by `receipts/bkard21b-drift-fixes.md` (ALIVE);
  the NFR rows BK-PPDOC/BK-NFRD1 edited are not among the drifted rows.

## 4. NFR rows post-BK-NFRD1 (JA-7 re-point + dual-figure prose)

Confirmed as receipted:

- **NFR-DUR-002 JA-7 re-point**: PRD §3 cites `../v26.10.21/receipts/ja7-crash-only-court.md`
  (standing line: "ALIVE — court file green 2 consecutive runs, 6/6 legs"). The receipt's
  JA-7.3 line reads verbatim `[JA-7.3] cycle cascade ms: 1 0 0 0 0 0 0 0 0 0` — the PRD's
  "≤1ms every cycle, 0ms in 9/10" is disk-exact. Closure receipt `../v26.10.21/receipts/amqp10-court-closure.md`
  exists; run 2 = 5/5 PASS, ADV-1 mid-frame-RST cascade 0–1 ms ×3 — "PASS ×2" claim supported.
  BK-NFRD1's own receipt (`receipts/bknfrd1-label-fix.md`) documents the re-point
  (before: "no receipt labeled JA-7"; after: label resolves, before/after §3 rows shown).
- **NFR-EVI-001 dual-figure prose**: PRD §3's "sync token: fixed 320 B (BK-92 cross-mint,
  layout-pinned); pplan seal term: 48 words = 384 B (PB4-R re-run; was 40 words pre-GAP-6a)"
  matches `receipts/bkrsize-receipt-truth.md` exactly: two different surfaces, sync token
  byte_size=320 re-measured, seal term 46 heap words at 0-step / 48 at n≥1, PB4-R real not
  artifact. §4's COURT-MERKLE-O1 mis-citation (F1) is the only residual on this NFR.

## Verdict

17/18 cells disk-true with green re-runs of the two registered internal courts; 1 typed
finding F1 (standing-citation mismatch on COURT-MERKLE-O1, owner BK-PRDR, fix is a
citation re-point to two ALIVE in-tree receipts). Whole matrix NOT fully disk-true →
standing PARTIAL_ALIVE.

## See Also

- `docs/jira/v26.10.22/PRD.md` §4/§4a — the audited matrix
- `docs/jira/v26.10.22/receipts/bkprdr-prd-matrix.md` — refresh provenance
- `docs/jira/v26.10.22/receipts/bkard21-terminal-audit.md` — first-pass board audit
- `docs/jira/v26.10.22/receipts/bkrsize-receipt-truth.md`, `receipts/pb4r-identity-court.md` — the receipts F1 should cite
