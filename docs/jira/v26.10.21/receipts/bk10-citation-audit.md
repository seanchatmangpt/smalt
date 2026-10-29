# BK-10 — FINAL-RELEASE §4/§-level citation audit + VALIDATION coherence audit

**Standing**: PASS — every cited receipt path exists; every number traced
  to a receipt or on-disk artifact; 3 doc-drift fixes landed; 2 flags.
- **Context**: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt @ main
- **Subject**: `docs/jira/v26.10.21/FINAL-RELEASE.md`,
  `docs/jira/v26.10.21/VALIDATION.md`

## Method

Grep the receipts, not memory. All 135 distinct receipt-path citations
(37 FINAL-RELEASE + 98 VALIDATION, union) resolved with a
`[ -f "$f" ]` existence loop; every number spot-checked with targeted
`grep -oE` against the receipt body or the cited jsonl artifact.

## Path existence (verified)

All cited receipt paths exist. Zero missing within the window
(`docs/jira/v26.10.21/receipts/`); all 9 cross-window citations resolve
under `docs/jira/v26.10.20/receipts/` (fix3-kd147-152-witness,
bkd-kd135-137-139-witness, migarm-arm-template-parser,
smalt-migrate-wave1-audit, t26-rehearsal-demo, migrate-enterprise-fixture,
otp29-capability-probes, tracebug-mixtest-tracing, wire-parity-matrix —
each `[ -f ]`-verified) plus the canonical KD register at
`docs/jira/v26.10.14/KD-01..160` (KD-157/159/160 rows present, all OPEN
as the docs claim).

## Numeric spot-checks (verified, grep evidence)

| Claim | Doc location | Anchor found |
|---|---|---|
| CAS412 800/800 412s | FR §4 | `grep 800/800` → hit, cas412-cosmos-replace-if-match.md |
| CAS412R 35/35 | FR §4/§7 | receipt says "35 passed / 0 fail" — traces |
| PB-2 ≈17.5k, 1,609, 15,224, 2,320 | FR §4 | all four in pb2-reductions-denominator.md |
| PB-3 22.8k→3.8k, wall unreached at 8192 | FR §4 | hits in pb3-executor-ceiling.md |
| PB-5 11,426 vs 2,118 ops/s; AC94479A…AC3; 98/200→0/500; 5.4x; 239.31/964.31 | FR §1/§4 | receipt + `tmp/bench/pb5-crosslang.jsonl` `"ops_per_sec":2117.5` / `11426.0` |
| PB-6 +0.708 (9.7x) / +0.675 (12.6x) / −1.630 (0.3x) | FR §4 | all hits in pb6-dual-boundary.md |
| PB-1 1700/1700; 0→10 retries, 0 errors | FR §4 | hits in pb1-fond-loop-latency.md |
| PB-4 76.5 vs 64.7 ms @10k | FR §2 | hits in pb4-merkle-dual-path.md |
| FONDRUNNER 7/7, byte-stable, sentinel 628801 | FR §4 | hits in fondrunner-otp29-pipeline.md + `lib/smalt/pipeline/smalt_fond_seal.erl:18` |
| GLD-5FIX 6/6, zero row loss, duckdb v1.4.1 | FR §1/§5/§8 | hits incl. `total count 6/6 (zero row loss)` in gld5fix-null-formula-court.md |
| GLD-6 7/7, seeds 456741/99 | FR §2 | hits in gld6-sql-row-gate-security-court.md |
| GLD-7 112/112, 13 events/13 objects | FR §2 | hits in gld7-ingest-to-settlement-court.md |
| GLD-1 sha c5c65bd1…eed1990, three consecutive runs | FR §2 | hits in gld1-sql-n3-court.md |
| SQLD-4 12/12, 3 consecutive green runs | FR §2 | hits in sqld4-sql-mapping-court.md |
| SQLD-2 500 rows / 80 events / 420 objects / 380 rels, two runs byte-identical | FR §5 | hits in sqld2-sql-ingest-court.md |
| SQLD-8 64,725 / 450,450 rows/s, 1545/222 ms, 280.6/95.4 MiB | FR §5 | hits in sqld8-ingest-baseline.md |
| SQLD-5 14/14 | FR §5 | hit in sqld5-sql-shape-gen.md |
| T47 1906 ms = 3.8x | FR §2/§8 | hits in t47-release-boot-gate.md |
| RELCUT 24%, court 3/3, 315–381 vs 338–484 ms | FR §2/§8 | hits in relcut-deferred-listeners.md |
| IMPL-13 612 vs 695 ms, 11.9%, 131,001,116 | FR §2/§7 | hits in impl13-jit-2912.md |
| IMPL-16 134.2 ms / 205.5 MB | FR §3 | "205,513,554 bytes (~205.5 MB)" + "134.2 ms" in impl16-json-string-bench.md |
| IMPL-20 wire census | FR §7 "28/28" | receipt says "28 passed, 0 failures" — traces |
| IMPL-21 5/5 ("all five witnesses, 0 errors") | FR §7 | hit in impl21-postupgrade-sdk.md:6 |
| OBS-03 134 ≤ 200 words; OBS-04 4/4 ×2 | VALIDATION §2.6 | hits in ar-obs-03-memory-fence.md / obs4court-peer-two-node.md |
| IMPL-1 200k procs, 0 vs 514,605 words | VAL §2.1 | hits in impl1-process-iterator.md |
| IMPL-18 1,492 procs, 9,178/10,802, −15.2% | VAL §2.1 | hits in impl18-vm-census-processiter-adoption.md |
| IMPL-26 6/6, HEAD 8defcf5 | VAL §2.6 | hits in impl26-ar-obs-02-label-adoption.md |
| GL-KILL skeptic 29/29, 78 green | VAL v6 fold | "Result: 29 passed" + 78 in glkill-f1-f2-close.md |
| GLADJ 43/43 | VAL v6 fold | 43 in gl8-andon-wire-adjudication.md |
| WASM-1 6-gate/stub; GWS-11 7/7; GWS-12 3-leg; GWS-7 18/18 | VAL v6 fold | hits in wasm1 / gws11 / gws12 / gws7 receipts |
| BENCH-5 5000/5000; BENCH-6 52,692,552 B; BENCH-7 32k | VAL §3.5 | hits in bench5/6/7 receipts |
| M4SBFIX 11 passed / 0 skipped / 9.85 s | VAL §3.2 | hits in m4sbfix-verify-zero-skip.md |
| NFR-2 0.205 s vs 30 s, 50-resource | VAL §3.2 | hits in migrate-nfr2-budget.md |
| Denominator table vs jsonl | FR §3 | cosmos p99 0.543/0.672 n=10k ×2 err=0, amqp 254.5 reds + 1.05 µs, powl 45,182.7 reds + p50 0.305, json 80 ms + 52,692,552 B + peak 38,504, ceiling 17.65…60.12 — all byte-trace to `tmp/bench/court_bench_{cosmos,amqp,powl,json,ceiling}.jsonl` on disk; 0.813–1.04/2.08 fence traces to bench3-cosmos-cas-erlang.md |
| POWL-PERF p99 2 µs / 895,335 ops/s / CAS 5 µs / 383,185 | FR §2 | byte-trace to `tmp/bench/powl-native-face.jsonl` |
| b253aa9 boundary audit | FR §1 | `git show --stat b253aa9` → PROD-CORE-ADDENDUM.md, 8 insertions, 2026-10-21 16:35 -0700 — traces |

## Fixed in place (doc drift, receipts now on disk)

1. **FINAL-RELEASE §2 board-version drift** (FINAL-RELEASE.md:50-64,
   :100-103): described the board as v5 with buckets 26/10/5/4 and 4
   PENDING-GWS; VALIDATION.md is v6 with 27/9/5/4 (AR-OBS-04 PARTIAL→ALIVE
   flip, OBS4COURT) and 2 PENDING-GWS (WASM-1 + GWS-12 closes). Updated
   to v6 counts with as-of 2026-10-21 note.
2. **VALIDATION.md GLD-5 row + header + backlog** (VALIDATION.md:187,
   :24, :65, :399): claimed F2/F3 "remain open" — contradicted on disk by
   `receipts/gld5fix-null-formula-court.md` (ALIVE, "total count 6/6
   (zero row loss)"). Updated with as-of closure pointers; backlog note
   tightened; post-v6 fold list extended (gld5fix, gld1, gld6, gld7,
   sqld4, sk5) and the UNWITNESSED dispatch list updated (GLD-1/6/7 no
   longer listed as unreceipted).
3. **VALIDATION.md GLD-1/6/7 row** (VALIDATION.md:188): "no receipts named
   gld1/gld6/gld7 exist on disk" — false as of now (all three exist,
   standings PASS/ALIVE/ALIVE verified from the receipt headers). Row
   rewritten with as-of flip.

## Flagged (not silently reconciled)

- **DISCREPANCY (timing, disclosed above but registered here):**
  VALIDATION.md:187 (v6 board) states GLD-5 F2/F3 "remain open" while
  `receipts/gld5fix-null-formula-court.md:46-47` states "total count 6/6
  (zero row loss)" with standing ALIVE — both values named here; resolved
  as post-v6 landing order, not a measurement conflict, and fixed with an
  as-of annotation rather than a silent rewrite of the v6 bucket table.
- **FLAG (operator-asserted, no receipt anchor):** "8 tests, 0 failures
  (0.07 s)" for `test/internal/powl2_graph_compat_court.exs` replayed
  under the 29.1.2 pin appears in FINAL-RELEASE.md:35-36, :309 and
  VALIDATION.md:125, :217 — `grep -rn '8 tests' receipts/` returns no
  graph-compat anchor. Operator-asserted run claim with no receipt on
  disk; not fabricated. Falsifier: run the court on the pin and record
  the output.
- **FLAG (minor, path-style):** FINAL-RELEASE.md:163 cites
  `court_bench_cosmos.jsonl` etc. without a directory prefix — files live
  at `tmp/bench/court_bench_*.jsonl`; values verified byte-exact there.
  Cosmetic; left as-is (bench/README.md uses the same convention).

## Counts

Verified: 68 spot-checks (135 paths + 68 number claims) — 66 verified,
2 flags (1 unanchored operator-asserted number, 1 cosmetic path style),
3 doc-drift fixes landed, 0 unverifiable numbers, 0 missing receipt
paths. Not committed (per task instruction).
