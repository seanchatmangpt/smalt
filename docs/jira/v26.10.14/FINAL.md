# FINAL — smalt v26.10.14 (terminal)

- **Landing**: commit `518b31a54ccc0829cafb9e04538714e58c287a30` (`518b31a`, main) — "v26.10.14: release work-order landing", 411 files, +45316/−1332; pushed `db2fe05..518b31a main`. No commits after the landing commit; fin30's landing receipt never landed, so the push SHA above is the terminal one.
- **court-x2**: two-green receipt NOT minted (DoD-07, standing PARTIAL_ALIVE); both flake faces closed (cosmos restart 105/0 ×3, auth-mode pinning landed); runnable on demand via `just court-x2`. No post-commit re-witness.
- **publish-dry**: all-PASS witnessed pre-commit only (DoD-08: tarball key/leak greps 0, regen identity); post-commit re-run NOT witnessed by any lane (swept — no receipt).
- **Post-commit gates (fin31, working-tree surface at HEAD 518b31a; tree never went clean, so committed-tree verdict remains UNKNOWN)** — 6/7 PASS:
  1. `mix compile --warnings-as-errors` — PASS
  2. `just doctor-dod` — PASS (0 FAIL, 2 WARN: orphan substrate lock; 342.1 MiB lane build root → `just lane-clean`)
  3. `python3 scripts/sdk_coverage.py` — PASS (PASS: 2, MISSING=0, UNREGISTERED-GAP=0, REGISTERED-DIVERGENCE=13; 52 KD rows loaded)
  4. `just gap-sync` — FAIL (register-semantics drift: `justfile.d/10-gap-register-sync.just:25` requires all KD rows OPEN, but KD-01/03/07/15/52 are closed with receipts; semantic fix handed to the owning lane)
  5. `just sobelow` — PASS (27 low-confidence informational findings, triaged in errc8-sobelow.md)
  6. `bash scripts/naming_sweep.sh` — PASS (0 violations / 52 allowed)
  7. `python3 scripts/gen_error_codes.py --check` — FAIL→PASS (mechanical fix: regenerated `docs/ERROR_CODES.md`, 70 rows, uncommitted with disclosure)
- **Publication gate**: signing.key rotation — coordinator decision, unchanged (fin-21).
- **Counts** (`just receipt-index`, re-witnessed by fin32): 124 receipt files + 15 SDK results = 139 indexed, 13 SUSPECT; 52 known divergences (KD-01..KD-52) — 47 OPEN, 5 closed with receipts (KD-01/03/07 s4-wire-normalization.md, KD-15 s3-kv-challenge.md, KD-52 x1-blocklist-fix.md); 17 bench results files under `bench/`; 1898 offline tests witnessed in court runs (flakes isolated, pass 105/0 and 21/0 in isolation); 20 release WOs + 12 ws + 8 cli + 14 DoD + fin lanes.
- **Standing mix** (RECEIPTS.md, regenerated 2026-10-15/16): see [RECEIPTS.md](RECEIPTS.md) for the per-lane table; 13 SUSPECT rows flagged for output-less receipts.
- **Planning handoff**: the v26.10.15 window is fully planned and on disk at [../v26.10.15/](../v26.10.15/) — `PLANNING.md` (window objective C1-C6 with witnessed v26.10.14 costs, ERRC adoption queue, execution order), `_LANES.md` (27-lane partition, clusters A-F), baseline `00-coordination-cost-baseline.md`, seeds `01-substrate-daemon.md` / `02-receipts-query-service.md` / `03-lane-build-cache.md` / `04-lane-slice-testing.md` / `05-superfans.md`, stubs `23-26` (substrate-proxy, sdk-docs-corpus-mining, flake-quarantine, seeded-cross-suite-regression), `RESOLUTIONS.md`, and `WAVE_TELEMETRY.md`. Every lane cites a witnessed v26.10.14 failure receipt; next session starts at execution order A + seams T1-T5, no planning residue.
- **Pointers**: [RECEIPTS.md](RECEIPTS.md) · [KNOWN_DIVERGENCES.md](KNOWN_DIVERGENCES.md) · [SDK_MATRIX.md](SDK_MATRIX.md) · [receipts/fin-21-final-wrap.md](receipts/fin-21-final-wrap.md) · [receipts/fin31-post-commit.md](receipts/fin31-post-commit.md) · [receipts/fin32-wrap-final.md](receipts/fin32-wrap-final.md)
