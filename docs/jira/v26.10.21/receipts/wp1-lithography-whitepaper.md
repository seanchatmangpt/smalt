# WP-1 — "Industrialization of Computation / Deterministic Software Lithography" whitepaper

**Standing**: ALIVE — paper written, compiled clean (0 LaTeX errors), PDF verified on disk.
- **Context**: solo
- **Date**: 2026-10-21 · Lane WP-1 · Repo /Users/sac/smalt @ main (uncommitted worktree, per task)
- **Artifacts**:
  - `/Users/sac/smalt/docs/jira/v26.10.21/whitepaper/lithography.tex`
  - `/Users/sac/smalt/docs/jira/v26.10.21/whitepaper/lithography.pdf` (7 pages, 202,528 bytes)

## Number-law compliance

Zero operator-asserted performance figures. Draft figures with no repo anchor were DROPPED and
replaced with measured values, per directive:

| Draft claim | Disposition | Measured replacement | Artifact |
|---|---|---|---|
| ≤2.0 µs WAL append | DROPPED (no anchor) | Journal seal protocol cited structurally (5-leg SJ-1 court) | `tmp/bench`/`sj1-journal-sink-writer.md` |
| 1.842 ms / 10^7 rows | DROPPED (no anchor) | sqld8: 450,450.5 rows/s direct projection; 64,724.9 rows/s converter | `tmp/bench/sqld8-ingest-baseline.jsonl` |
| 352-byte Ξ_CTRT | DROPPED (no anchor) | Measured receipt term 40 words = 320 B, O(1) at n=10..10^5 | `tmp/bench/pb4-merkle-dual.jsonl` |
| 5.0 µs CAS | KEPT — anchored | Native CAS put-if-match p99 5 µs, 383,186 ops/s | `tmp/bench/powl-native-face.jsonl` |
| <0.2 ms Merkle verify | DROPPED (no anchor) | Seal ladder p50 0.024/0.314/64.7/656.1 ms @10/100/10k/100k leaves | `tmp/bench/pb4-merkle-dual.jsonl` + `pb4-merkle-dual-path.md` |
| ∇C=0 | DROPPED (no anchor) | Cross-engine byte-identity legs (native/wasm/duckdb) | `gws12-cross-engine-determinism.md` |

## Measured figure count: 26 distinct figures, all artifact-cited

1. Cosmos TLS point read p99 0.543 / 0.672 ms, 2,251.4 / 2,130.0 ops/s — `tmp/bench/court_bench_cosmos.jsonl`
2. Native KV point read p99 2 µs, 895,335 ops/s — `tmp/bench/powl-native-face.jsonl`
3. Native CAS put-if-match p99 5 µs, 383,186 ops/s — `tmp/bench/powl-native-face.jsonl`
4. Wire-face point read p99 0.813 ms (estimate-only decomposition noted) — `tmp/bench/powl-native-face.jsonl`
5. AMQP frame decode 952,381 frames/s, 1.05 µs/frame, 254.5 reds/frame — `tmp/bench/court_bench_amqp.jsonl`
6. 4-step settlement 3,222.3 ops/s, p99 0.425 ms, 45,182.7 reds/op — `tmp/bench/court_bench_powl.jsonl`
7. Execute-only settlement p50 30 µs / p99 74 µs — `tmp/bench/powl-native-face.jsonl`
8. Cross-language parity 2,117.5 vs 11,426 ops/s — `tmp/bench/pb5-crosslang.jsonl`
9. Governance tax 0.25 µs/step median, +47.24 reds/step; guarded p99 0.976–1.147 ms — `tmp/bench/gl9-governance-tax.jsonl` + `docs/jira/v26.10.21/receipts/gl9-governance-tax.md`
10. 50 MB JSON SAX stream: 80 ms min wall, peak heap 38,504 B — `tmp/bench/court_bench_json.jsonl`
11. Ceiling sweep 0.9–1.18 µs/RT, reds/RT 17.65→60.12 — `tmp/bench/court_bench_ceiling.jsonl`
12. Columnar projection 450,450.5 rows/s, peak RSS 100.0 MB — `tmp/bench/sqld8-ingest-baseline.jsonl`
13. Dump converter 64,724.9 rows/s, peak RSS 294.2 MB — `tmp/bench/sqld8-ingest-baseline.jsonl`
14. Merkle seal ladder 0.024/0.314/64.7/656.1 ms @10/100/10k/100k — `tmp/bench/pb4-merkle-dual.jsonl`
15. Receipt term 40 words = 320 B at every n — `tmp/bench/pb4-merkle-dual.jsonl`
16. Falsified O(n) seal variant honestly recorded — `docs/jira/v26.10.21/receipts/pb4-merkle-dual-path.md`
17. Affidavit admit+seal p50 11.265 ms / p99 32.671 ms, engine sha256-pinned — `tmp/bench/c10-affidavit-seal.jsonl`
18. Crash-only: cascade 0–1 ms, +237 KiB/10 cycles flat — `docs/jira/v26.10.21/receipts/ja7-crash-only-court.md`
19. WASM caps 16 MiB request / 256 MiB budget / 64 MiB host ceiling — `docs/jira/v26.10.21/receipts/gws11-wasm-memory-wall.md`
20. Release cold boot 1,906 ms vs 500 ms ceiling — FAIL disclosed — `docs/jira/v26.10.21/receipts/t47-release-boot-gate.md`
21. GLD-7 loop: 112 assertions, 47-leaf sealed ledger, 32-byte HSM-signed root — `docs/jira/v26.10.21/receipts/gld7-ingest-to-settlement-court.md`
22. GLD-5FIX: 6/6 zero row loss, duckdb 1.4.1 — `docs/jira/v26.10.21/receipts/gld5fix-null-formula-court.md`
23. Cross-engine determinism 3/3 byte-identical legs, cross-language audit hash — `docs/jira/v26.10.21/receipts/gws12-cross-engine-determinism.md`
24. COLD-1 audit hash 6971c912… reproduced byte-exactly — `gws12-cross-engine-determinism.md`
25. JA-14: hot-upgrade UNSUPPORTED (zero .appup/.relup/code_change ×34) — `ja14-release-handling.md`
26. JA-16 D1–D3 open defects — `ja16-robustness-census.md`

## Compile receipt

```
$ cd /Users/sac/smalt/docs/jira/v26.10.21/whitepaper
$ /Library/TeX/texbin/pdflatex -interaction=nonstopmode lithography.tex   # ×2 (refs)
exit=0, 0 LaTeX errors
Pages: 7 (pdfinfo)
lithography.pdf  202,528 bytes
```

Fix-forward history: initial compile exit 0; two wide tables re-scoped with `\resizebox`
(remaining Overfull-hbox notes are inside scaled boxes — cosmetic, no visual overflow).

## Scope discipline

Only `docs/jira/v26.10.21/whitepaper/` and scratch under `/tmp/wp1/` were written; `lib/`
and other docs untouched. Not committed, per task.
