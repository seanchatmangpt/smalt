# RECEIPT: S19-V0 census court (duckdb-wasm SQL vs scalar baseline, ratio fence)

Standing: REFUTED (fence died on real measurement — numbers below; claim retired, fix-forward)

## What ran (verbatim, 2026-11-05)

`cd popcorn_demo/duckdb-spike && node verify.mjs` (headless chromium via system
Chrome + playwright, cross-origin-isolated page). Extended harness:
`popcorn_demo/duckdb-spike/verify.mjs` (S19-V0 court phase appended after the
SPIKE leg). Exit 1 by design (fence REFUTED ⇒ allPass=false). Full console log
captured in session; jsonl rows emitted to
`popcorn_demo/bench/bench-s19.jsonl`.

Corpus: `popcorn_demo/duckdb-spike/scvd.jsonl`, 46 rows,
sha256 `f8ce4277de0fdd5f4d7afe0940fe46fb756172cd9ead3f5e952c691eac675e93`
(embedded in every jsonl row).

## Claim under test — S19-C1

duckdb-wasm SQL census aggregation is within 10× of an independent
sleep-free scalar baseline at census volume (the named ratio fence,
BENCH_SPEC §3 — no absolute ms bounds). Fence:
`sql_p99_us_median <= 10 * scalar_p99_us_median`, per op, 3-run median,
population fence (rows ≥ 1) checked before the fence and re-checked
fail-closed on the measured runs.

## Three-run table (p99 µs; node-side 3-run loop, per-run fresh duckdb instance)

| run | op1 count_by_phase sql/scalar | op2 median_wall_by_n sql/scalar | op3 max_p99_us sql/scalar | agree |
|---|---|---|---|---|
| 1 | 795 / 5 | 670 / 20 | 545 / 5 | true×3 |
| 2 | 625 / 5 | 755 / 10 | 460 / 5 | true×3 |
| 3 | 500 / 5 | 535 / 10 | 340 / 5 | true×3 |

Ratio math (median over 3 runs):

- count_by_phase: 625 / 5 = **125×** → REFUTED (fence ≤ 10×)
- median_vm_wall_ms_by_n: 670 / 10 = **67×** → REFUTED
- max_p99_us: 460 / 5 = **92×** → REFUTED

SQL vs scalar results agree byte-for-byte on all ops and runs (op3 required
mirroring duckdb's NULL-ignoring `max()` in the scalar reduce — first
implementation coerced missing `p99_us` to NaN; fixed, not fudged).

## Why it dies — and what the numbers actually mean

At 46-row census volume, duckdb-wasm pays ~340–760 µs fixed per-query
overhead (worker round-trip + planning) against a ~5–20 µs plain-JS
group-by. The ratio fence fails by an order of magnitude-plus on every op.
The SQL engine's value exists only where planning amortizes — at volume —
not at this corpus size. The correct reading is not "duckdb is slow"; it is
"the census-aggregation half of S19 must not route through duckdb-wasm at
n=46": the scalar path IS the census engine at this scale, duckdb-wasm stays
a volume-tier component.

Honest-scope note (per plan): v0 satisfies the census-aggregation half of
S19 ONLY. The sealed-segment leg is NOT exercised here — v1b closes that.

## Defects caught and fixed during the court (all session-introduced, disclosed)

1. **0.1 ms timer clamp**: first runs read scalar ops as 0 µs because Chrome
   clamps `performance.now()` to 0.1 ms without cross-origin isolation.
   Fix: verify.mjs's local server now sends COOP/COEP; page is
   crossOriginIsolated; timings honest at µs resolution. The EH wasm build
   runs fine under COI (witnessed).
2. **op3 agree=false**: scalar `Math.max(-Infinity, undefined)` → NaN for
   corpus rows without `p99_us`; duckdb `max()` ignores NULLs. Scalar reduce
   now skips missing values. Fixed mid-court, witnessed red→green.
3. **ms rounding collapsed µs values to 0** → ratio Infinity artifacts.
   All timings/p99s now reported in µs with the raw 3-run arrays embedded.

## Provenance

- SPIKE-ALIVE provenance: `popcorn_demo/duckdb-spike/RECEIPT.md`
  (`node verify.mjs` exit 0, 2026-10-20; same runner reused — the SPIKE leg
  re-verified exit-grade in every run of this court).
- Spec: `popcorn_demo/BENCH_SPEC.md` §3/§4 (ratio-fence + jsonl conventions).
- Results: `popcorn_demo/bench/bench-s19.jsonl` (3 rows, claim S19-C1,
  corpus sha256 + raw 3-run arrays embedded per row).
- Related KDs minted this lane: KD-198 / KD-199 / KD-200
  (`../KNOWN_DIVERGENCES.md`).

## Falsifier / replay

Rerun `node verify.mjs` in `popcorn_demo/duckdb-spike` — the fence verdict is
recomputed live; a PASS here requires ratio ≤ 10× on all three ops. The
fence is not vacuous: it REFUSED the real measurement above, and the pre-fix
defects (NaN max, timer clamp) flipped it between verdicts, i.e. the gate
can and does die.
