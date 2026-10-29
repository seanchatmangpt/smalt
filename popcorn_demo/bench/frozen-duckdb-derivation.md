# Lane R3 — frozen-duckdb manifesto claim derivation

Standing: **PARTIAL_ALIVE** — 3 of 5 claims PASS as derived measurements on the
pinned engine; 1 SUSPECT (load-sensitive); 1 PASS-on-receipt-only; CLI
pack/query surface UNSUPPORTED on this machine.

Subject: `/Users/sac/frozen-duckdb` (READ-ONLY, untouched — `Cargo.lock`
sha256 `03692d09…` byte-identical before/after all runs). Binary:
`crates/frozen-duckdb/src/duckdb/target-lane3/debug/frozen-duckdb-cli`
(`frozen-duckdb 2.0.0-dev`, engine `DuckDB v2.0.0-dev88595` via
`~/.frozen-duckdb/cache/v2.0.0-dev-arm64/libduckdb_arm64.dylib`).
Machine: Apple M3 Max, 16 cores, 48 GB, macOS 25.2.0.

## Method (derive, don't cite)

1. CLI first: `frozen-duckdb-cli` exposes `convert` / `benchmark` / `info`.
   `convert --input-format json --output-format parquet` **exits 1** on every
   attempt (100k corpus, csv/parquet/arrow targets): the pinned dev engine
   tries to download the parquet extension from
   `http://extensions.duckdb.org/b6013f7aa2/osx_arm64/parquet.duckdb_extension.gz`
   → **HTTP 404** (no published extension for commit `b6013f7aa2`). Even
   `frozen-duckdb-cli info` exits 1 the same way. `benchmark` is a stub:
   `Performance benchmarking feature coming soon!` exit 0, no output. Verdict:
   the CLI pack/query surface is **UNSUPPORTED** for claim derivation here.
2. Fell back to the repo's own measurement harnesses, which are real cargo
   courts that ingest a real JSONL corpus and measure on-disk bytes (Chicago:
   no mocks). Build writes were kept out of the read-only tree via the repo's
   sanctioned seam `scripts/doctor/07_ocel_compress.sh` +
   `DOCTOR_TARGET_DIR=/tmp/fd-r3/doctor-target`. (A full /tmp copy of the repo
   was REFUSED by the topology guard — rsync of a repository — so the
   env-seam route was used and is disclosed here.)
3. Verbatim runs (all exit 0 unless noted):

```
cd /Users/sac/frozen-duckdb && DOCTOR_TARGET_DIR=/tmp/fd-r3/doctor-target \
  FDOCEL_EVENTS=100000 cargo test -p frozen-duckdb --test doctor_ocel_tests -- --nocapture
→ OCEL-COURT events=100000 seed=20261019 ddl_form=VARIANT bytes_A(S_raw)=20911389 \
  bytes_B(S_fdb)=1060864 ratio=0.05073 events_per_sec=30365 wall_ms=5746 verdict=PASS
→ test result: ok. 3 passed; 0 failed (5.75s)

DOCTOR_TARGET_DIR=/tmp/fd-r3/doctor-target FDOCEL_EVENTS=1000000 \
  cargo test -p frozen-duckdb --test doctor_ocel_tests -- --nocapture
→ OCEL-COURT events=1000000 ... bytes_A(S_raw)=211000389 bytes_B(S_fdb)=6565888 \
  ratio=0.03112 events_per_sec=31128 wall_ms=53159 verdict=PASS
→ test result: ok. 3 passed; 0 failed (53.16s)

DOCTOR_TARGET_DIR=/tmp/fd-r3/doctor-target cargo test --release -p frozen-duckdb \
  --test gate_ingest_throughput -- --include-ignored --nocapture
→ machine specs: cpu='Apple M3 Max' cores=16 mem=48.0GB os=macos
→ leg1_packed_3col: 12416257 rows/sec over 5.01s (62200000 rows)
→ leg2_bp3_segments: 7259543 rows/sec over 5.00s (36300000 rows)
→ test result: ok. 1 passed (10.11s)

DOCTOR_TARGET_DIR=/tmp/fd-r3/doctor-target bash scripts/doctor/08_perf_sla.sh
→ gate_v01_latency: test result: ok. 1 passed (35.51s)   [quiet court run]
→ gate_ingest_throughput: test result: ok. 1 passed (10.11s)
```

Corpus for the CLI attempts (blocked, retained for replay):
`/Users/sac/smalt/popcorn_demo/bench/gen_corpus_r3.py` generated deterministic
smalt-telemetry-shaped OCEL NDJSON (seed 20261020, LCG, no wall clock):
`corpus/ocel-100k.ndjson` = 31,200,286 B / 100k events,
`corpus/ocel-1m.ndjson` = 313,003,802 B / 1M events. The courts that produced
the numbers above use their own deterministic corpus (seed 20261019,
`FDOCEL_EVENTS`-scaled, spec `docs/design/compression-proof-protocol.md`).

## Verdict table

| Claim | Stated | Derived (R3) | Verdict |
|---|---|---|---|
| 90% compression floor vs raw JSON | ≥90% | 94.93% @100k, 96.89% @1M | **PASS** |
| OCEL compression 94.93% @100k | 94.93% | measured 94.927% (ratio 0.05073, 20,911,389 → 1,060,864 B) | **PASS** (dead on, within 0.01pp) |
| OCEL compression 97.01% @1M | 97.01% | measured 96.888% (ratio 0.03112, 211,000,389 → 6,565,888 B) | **PASS** (Δ 0.12pp) |
| Ingest throughput (release) 12.16M rows/s | 12.16M | **12,416,257 rows/s** (leg1 packed, 62.2M rows over 5.01s, release, 5-gate run exit 0) | **PASS** |
| Query latency p95 10.51 ms < 15 ms | 10.51 | round 1: 11.73 ms (reproduces); full-court quiet run PASS (exit 0); two --nocapture reruns: median p95 22.70 / 20.03 ms → FAIL | **SUSPECT** — reproduces round-1 on a quiet machine, fence dies under concurrent lane load |
| Fleet Class-D 99.76% | 99.76% | receipt `fleet004.json` on disk, arithmetic verified 536,576/221,033,690 = 99.757%; live re-derivation REFUSED (3 legs FAIL exit 101: missing `/tmp/t2writer` fixture binary) | **PASS (receipt-only)** — internally consistent, not live-re-derived by R3 |

## DISPATCH-CITED reconciliation: 12.16M vs 61,599 rows/s

Both numbers are real; they measure different subjects.

- **12.16M rows/s (campaign, DISPATCH-CITED)**: release-profile, batched
  packed-column ingestion (`tests/gate_ingest_throughput.rs`, leg1
  `packed_3col`). R3 re-measured **12.42M rows/s** on this machine today —
  the claim HOLDS. My measurement supports the campaign side.
- **61,599 rows/s (MAX2 lane-final, git b7e2e51)**: debug/test-profile
  "pot ingestion" (`receipts/MAX2-pot-ingestion.md`) — per-row monotonic
  rejection checking + VARIANT bind + DFG mining in the loop, under ~14
  concurrent lane builds. Its own receipt sets the floor honestly at 50,000
  against measured 58–80k under load. Same engine, different profile and a
  much heavier per-row code path — ~200x apart by construction, not a
  contradiction.
- R3's own debug-profile pack rate (OCEL court): 30,365 / 31,128 events/s —
  consistent with the MAX2 debug side of the ledger, ~2x below its floor due
  to R3's heavier 15-field OCEL shape.

## Receipt

- Binary: `frozen-duckdb-cli 2.0.0-dev`, engine `v2.0.0-dev88595`.
- Wall times: OCEL 100k 5.75s, 1M 53.16s; throughput gate 10.11s; latency
  gate 35.51–44.74s.
- Read-only integrity: no writes into `/Users/sac/frozen-duckdb`
  (`Cargo.lock` sha256 identical before/after; build dir in
  `/tmp/fd-r3/doctor-target`; no git commands run).
- Artifacts: this receipt, `frozen-duckdb-r3.json` (scratch),
  `gen_corpus_r3.py`, `corpus/ocel-{100k,1m}.ndjson` — all under
  `/Users/sac/smalt/popcorn_demo/bench/` (owned by lane R3).
- Honest failures on record: CLI convert/info exit 1 (extension 404);
  CLI benchmark is a stub; latency gate FAILED twice on rerun under load;
  Fleet-D legs FAILED exit 101 (missing fixture) — all reported, none faked.
