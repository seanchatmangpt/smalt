# BK-61 — VALIDATION.md v7 → v8 fold (post-v7 receipt wave)

**Standing:** ALIVE
- Context: solo
- Date: 2026-10-22 · Lane: BK-61 · Repo: /Users/sac/smalt @ main

## Fold summary

`docs/jira/v26.10.21/VALIDATION.md` v7 → v8 (mtime-checked before work:
board was at 20:01 Oct 21; worked on current disk state). Census: fresh
`ls` of `receipts/` (190 files) + `receipts/INDEX.md` vs the board's
citations; ~37 receipts landed post-v7 (mtime newer than the v7 board),
all operator-named paths `[ -f ]`-verified (0 missing).

## Cell-level changes (exactly four rows touched, zero bucket moves)

- **NFR-FOOTPRINT** — cold-start folded `receipts/ttv6-cold-boot-gate.md`
  (ALIVE): charter ceiling re-type 500 ms → 2,000 ms in `DIRECTIVES.md`
  with named falsifier + load-exclusion clause; measured best quiet boot
  1,906 ms passes the re-typed ceiling; the original T47 500 ms FAIL
  (3.8x) stands as measured history. Plus `receipts/bk33-warm-restart-rebind.md`
  (RESOLVED — heir-to-init ETS survival; warm restart rebinds 6/6
  listeners 3/3 under court).
- **AR-POWL-PERF** — folded `receipts/ttv7-warmed-p99-standard.md`
  (PARTIAL_ALIVE: warmed ms-tail reproduces under load, p50 6–7 µs —
  the v7 falsifier's p50 clause did NOT fire; cold-noise premise refuted,
  per-step compute exonerated via reds/step 285.4) and
  `receipts/ttv7b-quiesced-rerun.md` (BLOCKED-ON-QUIESCENCE — load never
  below 84.5 vs the 32 gate; quiet-tail adjudication still open).
- **NFR-COMPLIANCE** — folded the KD-register wave: register now spans
  KD-01..163 (BK-52 mints), closures bk14/19/24/25/26/29/39/43/48/55,
  censuses bk30/36/38/40, register repair bk34, conformance bk19.
- **PRD-BLOB** — folded `receipts/bk39-kd144-146-blob-fixes.md` (KD-144/145/146
  blob-face fixes, `# KD-COVERS`-pinned). **AR-SEC-01** — folded
  `receipts/bk6-validation-partial-closures.md` (SEC-01/WIRE-02/OBS-04
  premise-rot closure + live-twin TLS 1.3 re-witness).

## Counts

- `grep -c PENDING` before: 20 → after: 21 (one added mention: the TTV-7b
  BLOCKED-ON-QUIESCENCE fold on the AR-POWL-PERF row). Row-level PENDING: 0;
  Row-level PENDING-PB: 0; Row-level PENDING-GWS: 2 — unchanged.
- Cell buckets unchanged: 27 ALIVE-class / 9 PARTIAL / 5 REFUTED /
  4 UNSUPPORTED-FAIL = 45 cells.
- Not flipped: SYNC/TIV-5/PAT lane cells (lanes still running). bk58/59/60
  do not exist on disk; BENCH-2/4/12 still unreceipted — stated, not papered.

## Gates

- Every cited path `[ -f ]`-verified (37 paths, 0 missing).
- `just docs-dod-check`: **exit 0** (all 63 checks OK).
- Not committed (per task).
