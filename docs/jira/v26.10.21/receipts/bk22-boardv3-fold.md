# BK-22 — BOARDV3 fold: VALIDATION.md v6 → v7 + _LANES.md drift repair

**Standing:** **ALIVE as artifact** (board v7 landed; every cited receipt path
`[ -f ]`-verified on disk; `just docs-dod-check` exit 0)

Context: solo

Date: 2026-10-21 · Lane: BK-22 (BOARDV3 fold) · Repo: /Users/sac/smalt
Files owned: `docs/jira/v26.10.21/_LANES.md`,
`docs/jira/v26.10.21/VALIDATION.md`

## What flipped

VALIDATION.md v6 → v7 (BOARDV3 fold):

- **AR-POWL-PERF (POWLBENCH) row**: no longer cites the 74 µs-only claim.
  Now reflects `receipts/powlbench-fresh-rerun.md` (PARTIAL_ALIVE, lane
  bk5): fresh settlement p50/p95 reproduce the cited regime (29/77 µs) but
  **p99 373 µs breaches the AR-PROD-05 ≤100 µs gate and the 200 µs
  falsifier under machine load**, typed not smoothed; mutant leg
  non-vacuous (p50 3.9x move). New falsifier clause added: a
  quiet-machine re-run where p50 also exceeds 100 µs escalates
  AR-PROD-05 to failing.
- **AR-SEC-01 row**: folded the ML-KEM flip evidence
  (`receipts/imp14-mlkem-flip.md`, PARTIAL_ALIVE): `supported_groups`
  `[:x25519mlkem768, :x25519, :secp256r1]` on the tlsv1.3 gate; OTP-29
  default-equivalence witnessed (the pin is behaviorally a no-op on OTP 29
  today); live 9444 twin mlkem negotiation + curl regression 200; **Go
  mlkem-only single-shot pin typed client-side UNSUPPORTED** (Go 1.24
  refuses a CurvePreferences without an ECDHE curve; the identical offer
  succeeds from an OTP 29 client); azidentity leg stays typed-open.
  Residual (c) added to the falsifier column.
- **GWS-SANDBOX-GATES / GWS-DETERMINISM rows**: already CLOSED in v6
  (ALIVE-on-stub / PASS); receipts (`wasm1-otp29-sandbox-port.md`,
  `gws12-cross-engine-determinism.md`) `[ -f ]`-verified on disk and the
  rows annotated "As-of v7 (BK-22 fold): receipt `[ -f ]`-verified on
  disk 2026-10-21".
- **Header + standing paragraph**: bumped to v7 with the BOARDV3 fold
  lineage; provenance gained the post-v6 landing list (powlbench-fresh-rerun,
  imp14-mlkem-flip, bk10/bk15/bk17/bk20/bk9 receipts).
- **Untouched as directed**: AR-OBS-04 and AR-WIRE-02 rows (BK-6 owns
  them, still running).

_LANES.md drift repair + fold:

- **Row 85 (PB-1/2/5/6 "receipts not yet landed" UNWITNESSED)**:
  corrected — all six PB receipts exist on disk (pb1..pb6) plus
  `powlbench-fresh-rerun.md`; row now carries per-receipt standings and
  cites the BK-5 premise correction.
- Two malformed table artifacts repaired in the first v7 section: the
  `| receipts | receipts | receipts |` header row (broke the post-v6
  landings table) and a dangling duplicate table header left between the
  v7 section and its duplicate copy.
- Appended **v7.1 BOARDV3 fold section**: BK-1/2/3/4/5/9/10/11/13/15/
  16/17/18/20, JA-5/7/16, JA-R2, JA-R3, WP-1, TTV-8, and TTV-4/7 +
  BK-16 registered (TTV-4/7 and BK-16 UNWITNESSED — no receipts on
  disk; rows flip only on their own receipts). Receipt count line
  updated 129 → 145.

## PENDING count before/after

- Before (v6 disk state): `grep -c PENDING VALIDATION.md` = **21**
- After (v7): **21** — unchanged, correctly: the two row-level PENDING
  rows that remain are GWS-IN-WASM-COURTS (PENDING-GWS-14) and
  GWS-SEC-FUZZ (PENDING-GWS-15); OBS-04/WIRE-02 were never PENDING (both
  already ALIVE/ALIVE-on-pinned); all other PENDING mentions are lineage
  prose (v5's 4 PENDING-GWS rows, the resolved PENDING-PB bucket, the
  verdict-vocabulary definition). No row flipped to PENDING and none was
  hidden.

## Verification

- Every receipt path cited in both files verified on disk:
  `receipts/` paths all exist under `docs/jira/v26.10.21/receipts/`;
  the `../v26.10.20/receipts/` citations all exist (11 files re-checked).
- `just docs-dod-check` → **exit 0** (all named doc paths OK).
- `grep -c PENDING VALIDATION.md` → 21 (before) / 21 (after).
- BK-6's OBS-04/WIRE-02 rows byte-untouched.

## Falsifier

Any receipt path named in `_LANES.md` or `VALIDATION.md` failing
`[ -f ]`, or `docs-dod-check` exiting non-zero post-fold, reopens this
receipt.
