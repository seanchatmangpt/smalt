# Smalt Benchmarks & Unfinished Surfaces Audit (v26.11.15)

**Milestone:** v26.11.15  
**Auditor:** Agent 17 (Smalt Benchmarks & Unfinished Surfaces Auditor)  
**Target Repository:** `/Users/sac/smalt`  
**Execution Context:** Apple M3 Max (16 physical cores, 48 GiB RAM, macOS Darwin 26.2), Erlang/OTP 29.1.2, Elixir 1.20.4, Go 1.24  
**Date:** 2026-11-16T17:55:00Z  
**Status:** COMPLETE AUDIT RECEIPT  

---

## 1. Executive Summary

This audit assesses the performance benchmarking infrastructure, production readiness, and architectural completeness of `/Users/sac/smalt`. The audit verified live benchmark execution, investigated test and harness anti-vacuity, documented unbenchmarked operational surfaces, and cataloged architectural gaps across the core BEAM emulator, the `posh` Go membrane, the Sovereign Console web application (`workspace/`), the `smalt-cli` Python tool, the generated `cli/` (`smaltctl`), and adapter integrations.

### Key Findings Snapshot
1. **Critical Harness Vacuity in `bin/court-bench`:** The primary Erlang bench court escript compiles 13 production benchmark modules, but fails to execute any of them. Because `smalt_bench_court:run_all/0` is not exported by `bench/smalt_bench_court.erl`, `bin/court-bench` silently falls back to executing 3 trivial in-memory stubs (`stub-noop`, `stub-count`, `stub-arith`), reporting a false `COURT PASS` while 12 real benchmark modules remain unexecuted.
2. **Brittle Wall-Clock Gate in `bench_json_streaming.erl`:** Native `:json` SAX streaming throughput benchmark enforces an absolute wall-clock threshold of `<= 100ms` over a 50.3 MiB synthetic Cosmos JSON corpus. On modern Apple Silicon under ambient load, the benchmark achieves 110ms–116ms (peak heap 33 KB, well under the 2 MiB ceiling), triggering `PASS_HEAP_WALL_EXCEEDED` and failing closed with exit code 1.
3. **Substrate Boot Failure in `scripts/bench.py`:** The root PRD CTQ benchmark script (`python3 scripts/bench.py`) attempts to boot a local substrate with `MIX_ENV=dev`. Because dev dependencies are not vendored or installed in `deps/`, the substrate exits with code 1 before binding port `:9443`, rendering `just bench` unusable out-of-the-box without manual dependency intervention.
4. **`popcorn_demo` Dependency Rot:** The `popcorn-bench-scvd` harness fails with exit code 1 due to missing Hex dependencies (`jason`, `popcorn`) in `popcorn_demo/`, blocking automated SCVD baseline measurements.
5. **Major Unbenchmarked Surfaces:** No automated throughput, latency, or concurrency benchmarks exist for Blob Storage (PUT/GET block, append, page), Key Vault 7.4 REST data plane, Azure App Configuration CAS, Confidential Ledger transaction certification, Kinesis SigV4 streaming, MCP tool surface (port 9545), `smaltctl` Rust CLI, `smalt-cli` Python CLI, or the Terraform provider adapter.
6. **Outstanding Tokens & Architectural Transitions:** `PENDING-BENCH-1` (`scripts/bench/erlang_bench.escript`) and `PENDING-BENCH-2` (GL-9 pure-Erlang governance tax court) remain unresolved since v26.10.21. The v26.10.31 transition separating proprietary ARM dialects into the `posh` Go membrane while keeping BEAM core standard-pure remains partially implemented with cordoned port handoffs.

---

## 2. Live Benchmark Execution Receipts

All benchmarks below were executed live during this audit session. Exact commands, exit codes, and verbatim outputs are recorded.

### 2.1. Pure-Erlang Court Runner (`bin/court-bench` / `just court-bench`)
* **Module / File:** `bin/court-bench`, `bench/smalt_bench_court.erl`
* **Objective:** Compile all Erlang benchmark modules in `bench/*.erl` and run the court harness.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && just court-bench
  ```
* **Exit Code:** `0` (False PASS / Stub Fallback)
* **Verbatim Output:**
  ```
  #!/usr/bin/env bash
  set -euo pipefail
  export PATH="/opt/homebrew/opt/erlang@29/bin:$PATH"
  test -x "/Users/sac/smalt/bin/court-bench" \
      || { echo "[court-bench] MISSING /Users/sac/smalt/bin/court-bench"; exit 1; }
  cd "/Users/sac/smalt"
  exec ./bin/court-bench "${COURT_BENCH_DIR:-bench}"
  [court-bench] root=/Users/sac/smalt/bin/.. benches=/Users/sac/smalt/bench
  [court-bench] compiled 13 module(s): bench_amqp_frame, bench_aq_boundary_alloc, bench_bc_lane, bench_bc_sink, bench_concurrency_ceiling, bench_cosmos_cas, bench_json_streaming, bench_powl_pipeline, bench_zp19_slab_window, cgap_beam, court_receipt, kafka_vs_aoq_court, smalt_bench_court
  [court-bench] run_all/0 absent — fallback: run_all/1 stub set
  [court-bench] COURT PASS rows=3 receipt=tmp/bench/court_bench_20261116T173858.299Z.jsonl
  ```
* **Emitted Receipt Analysis (`tmp/bench/court_bench_20261116T173858.299Z.jsonl`):**
  ```json
  {"name":"stub-noop","n":1000,"wall_ms":0.006,"ops_sec":175192711.983,"ns_per_op":5.708,"reds_per_op":4.002,"heap_delta":0,"driver_wall_ms":0.005,"driver_reds_per_op":0}
  {"name":"stub-count","n":500,"wall_ms":0.516,"ops_sec":968992.248,"ns_per_op":1032,"reds_per_op":40.006,"heap_delta":0,"driver_wall_ms":0.002,"driver_reds_per_op":0}
  {"name":"stub-arith","n":200,"wall_ms":0.028,"ops_sec":7153587.524,"ns_per_op":139.79,"reds_per_op":0,"heap_delta":1872,"driver_wall_ms":0.01,"driver_reds_per_op":20}
  ```
* **Audit Finding:** The script compiles 13 benchmark modules (`bench_amqp_frame`, `bench_aq_boundary_alloc`, `bench_bc_lane`, `bench_cosmos_cas`, `bench_json_streaming`, `bench_powl_pipeline`, `bench_zp19_slab_window`, etc.), but executes only 3 mock functions (`stub-noop`, `stub-count`, `stub-arith`). The real benchmark targets registered via `smalt_bench_court:add_target/3` or defined in standalone modules are never exercised by the official court runner.

---

### 2.2. Native `:json` SAX Streaming Benchmark (`bench/bench_json_streaming.erl`)
* **Module / File:** `bench/bench_json_streaming.erl`
* **Objective:** Benchmark native Erlang `:json` SAX streaming (`decode_start/3` + `decode_continue/2`) over a deterministic 50.3 MiB Cosmos JSON corpus.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa _bench-escript/ebin -noshell -s bench_json_streaming menu -s init stop
  ```
* **Exit Code:** `1` (Failure)
* **Verbatim Output:**
  ```
  corpus: 52692552 bytes (50.3 MiB), 22551 docs
  json_sax_stream run1: 110 ms, peak_heap=33344 B (0.0 MiB)
  json_sax_stream run2: 116 ms, peak_heap=37848 B (0.0 MiB)
  json_sax_stream run3: 114 ms, peak_heap=20904 B (0.0 MiB)
  verdict: PASS_HEAP_WALL_EXCEEDED (min 110 ms / max peak 37848 bytes)
  ```
* **Audit Finding:** The memory gate `MaxPeak =< 2*1024*1024` passed decisively (peak heap was only 37.8 KB). However, the absolute wall-clock gate `MinWall =< 100` failed because minimum wall time was 110 ms. Flaky absolute wall-clock thresholds in CI/bench courts violate deterministic admission laws.

---

### 2.3. Pure-Erlang FOND/POWL Settlement Pipeline (`bench/bench_powl_pipeline.erl`)
* **Module / File:** `bench/bench_powl_pipeline.erl`, `lib/smalt/pipeline/smalt_fond_powl_runner.erl`
* **Objective:** Measure in-process MFA execution of the pure-Erlang FOND/POWL runner performing N=5000 4-step settlement orchestrations.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa _bench-powl/ebin -noshell -eval 'bench_powl_pipeline:main().'
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output (Summary Tail):**
  ```
  BENCH5 n=5000 ok=5000 errors=0 agg_wall_ms=3858.7 ops_per_sec=1295.8
  BENCH5 reds_per_op=43276.8 heap_delta_words=317811
  BENCH5 machine=#{cpu => "Apple M3 Max",darwin => "26.2",otp => 29,cores => 16,ram_gb => 48}
  ```
* **Emitted Receipt Tail (`tmp/bench/court_bench_powl.jsonl`):**
  ```json
  {"lane":"bench5","surface":"erlang_powl_runner_postfix","op":"settlement_orchestration_4step","n":5000,"ops_per_sec":1295.8,"errors":0,"machine":{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"otp":29,"darwin":"26.2"},"agg_wall_ms":3858.7,"reds_total":216384214,"reds_per_op":43276.8,"heap_delta_words":317811,"warmup":100}
  ```
* **Audit Finding:** Verified real state machine execution (`smalt_fond_powl_runner`) through 11 ledger steps per orchestration with Merkle root computation. Reductions per op (43,276.8) accurately capture caller and gen_statem termination work.

---

### 2.4. Pure-Erlang AMQP Frame Decoding (`bench/bench_amqp_frame.erl`)
* **Module / File:** `bench/bench_amqp_frame.erl`, `lib/smalt/messaging/amqp/frame_codec.ex`
* **Objective:** Benchmark decoding of 100,000 AMQP transfer frames (1,582 bytes each, Service Bus dialect) via the compiled `Elixir.Smalt.Amqp.FrameCodec`.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa /Users/sac/.asdf/installs/elixir/1.20.4-otp-29/lib/elixir/ebin -pa _bench-aq/dev/lib/smalt/ebin -pa _bench-escript/ebin -noshell -s bench_amqp_frame run -s init stop
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output:**
  ```
  frame_bytes=1582
  AMQPFRAME otp=29 erts=17.x n=100000 best_wall_ms=126 best_reductions=25450054 us_per_frame=1.26 reds_per_frame=254.5 ops_per_sec=793651
  ```
* **Emitted Receipt Tail (`tmp/bench/court_bench_amqp.jsonl`):**
  ```json
  {"lane":"bench4-amqp-frame","surface":"amqp_frame_decode","op":"decode_frame","n":100000,"frame_bytes":1582,"ops_per_sec":793651,"p50_ms":128,"p95_ms":130,"p99_ms":130,"best_reductions":25450054,"reds_per_frame":254.5,"us_per_frame":1.26,"errors":0,"machine":"Apple M3 Max/otp-29.1.2"}
  ```
* **Audit Finding:** Verified parity with the IMPL-13 JIT baseline (254.5 reds/frame vs 254.3 baseline, Δ = 0.08%).

---

### 2.5. ZP-19 Slab/TLS WindowBuffer NIF Soak (`bench/bench_zp19_slab_window.erl`)
* **Module / File:** `bench/bench_zp19_slab_window.erl`, `bench/cgap_beam.erl`, `priv/aoq/aq_beam_nif`
* **Objective:** Measure per-op allocation and size-invariance of the AOQ slab/TLS WindowBuffer path via native C NIF.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa _bench-escript/ebin -noshell -s bench_zp19_slab_window run -s init stop
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output:**
  ```
  == ZP-19 slab/TLS WindowBuffer soak (aq_slab_window) ==
  dylib: priv/aoq/aq_beam_nif (SMALT_ROOT=false)
  S=1 words/op=14 B/op=112 twin_words_per_op=4.0 verdict={floor,{twin_words_per_op,4.0}}
  S=256 words/op=14 B/op=112 twin_words_per_op=514.0 verdict={ratio_pass,0.027237354085603113}
  S=4080 words/op=14 B/op=112 twin_words_per_op=8162.0 verdict={ratio_pass,0.0017152658662092624}
  F1 size-invariance: words(4080)-words(1)=0 (fence <= 4) -> 'PASS'
  F3 anti-vacuity: oob=error badrange=error unstamped=error

  CTQ-03-sidecar row (measured, this run):
    S=1 B/op=112 words/op=14 verdict={floor,{twin_words_per_op,4.0}}
    S=256 B/op=112 words/op=14 verdict={ratio_pass,0.027237354085603113}
    S=4080 B/op=112 words/op=14 verdict={ratio_pass,0.0017152658662092624}
  F1 size-invariance -> 'PASS';  F3 refusal paths -> 'PASS'
  SOAK GATE: 'PASS'
  ```
* **Audit Finding:** Proves zero-allocation scaling (`words(4080) - words(1) == 0`). Anti-vacuity paths explicitly verify that out-of-bounds, out-of-range, and unstamped slots return `error`.

---

### 2.6. BC Bench Lane (`bench/bench_bc_lane.erl`)
* **Module / File:** `bench/bench_bc_lane.erl`, `bench/bench_bc_sink.erl`, `lib/smalt/aoq/`
* **Objective:** Execute paired min-of-7 interleaved rounds for SASL PLAIN admission, AOQ partitioned ring submit, and PartitionLog produce engine overhead.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa _bc-laneBC/ebin -pa _bench-escript/ebin -pa /Users/sac/.asdf/installs/elixir/1.20.4-otp-29/lib/elixir/ebin -pa _build-laneHS/test/lib/*/ebin -noshell -s bench_bc_lane run -s init stop
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output:**
  ```
  BC FENCED RUN PASS
  ```
* **Emitted Receipt Tail (`docs/jira/v26.11.6/bench/bc.jsonl`):**
  ```json
  {"name":"bc_pool_submit","wall_ms":47.269792,"ops_sec":423103.194531,"ns_per_op":2363.4896,"reds_per_op":290.49405,"n":20000,"rounds":7,"heap_delta_bytes":12792}
  {"name":"bc_ring_submit","wall_ms":27.782708,"ops_sec":719872.231317,"ns_per_op":1389.1354,"reds_per_op":61.23265,"n":20000,"rounds":7,"heap_delta_bytes":7904}
  {"name":"bc_sasl_plain_admit","wall_ms":55.843209,"ops_per_sec":3581456.072841,"ns_per_op":279.216045,"reds_per_op":15.02134,"n":200000,"rounds":7,"heap_delta_bytes":12792}
  {"fence":"bc_sasl_overhead_max","ratio":58.576813,"verdict":"pass"}
  {"fence":"bc_ring_pool_ratio_min","ratio":0.587748,"verdict":"pass"}
  {"fence":"bc_log_engine_overhead_max","ratio":0.977387,"verdict":"pass"}
  ```
* **Audit Finding:** All three calibrated ratio fences passed with real state resets between rounds. Note: The benchmark initially failed when dependencies were not loaded; it requires `_build-laneHS/test/lib/*/ebin` in the code path.

---

### 2.7. Actor Concurrency Ceiling (`bench/bench_concurrency_ceiling.erl`)
* **Module / File:** `bench/bench_concurrency_ceiling.erl`
* **Objective:** Measure pure-Erlang actor messaging overhead across process counts from 1,000 to 32,000.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa _bench-escript/ebin -noshell -s bench_concurrency_ceiling run -s init stop
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output:**
  ```
  wrote tmp/bench/court_bench_ceiling.jsonl (6 rows)
  ```
* **Emitted Data Tail (`tmp/bench/court_bench_ceiling.jsonl`):**
  ```json
  {"kind":"meta","module":"bench_concurrency_ceiling","n":null,"otp":"29","schedulers":16,"logical":16,"sweep_self_reds":4867814}
  {"kind":"row","n":1000,"rounds":50,"round_trips":50000,"wall_ns":61059208,"wall_ms":61.059208,"usec_per_roundtrip":1.22118416,"reds_per_roundtrip":3.31,"ops_per_sec":818877.3100365141}
  {"kind":"row","n":4000,"rounds":50,"round_trips":200000,"wall_ns":331738000,"wall_ms":331.738,"usec_per_roundtrip":1.65869,"reds_per_roundtrip":3.389225,"ops_per_sec":602885.409570203}
  {"kind":"row","n":8000,"rounds":50,"round_trips":400000,"wall_ns":644840958,"wall_ms":644.840958,"usec_per_roundtrip":1.612102395,"reds_per_roundtrip":3.28439,"ops_per_sec":620307.9922848201}
  {"kind":"row","n":16000,"rounds":20,"round_trips":320000,"wall_ns":498036833,"wall_ms":498.036833,"usec_per_roundtrip":1.5563651031249999,"reds_per_roundtrip":3.398490625,"ops_per_sec":642522.7589542558}
  {"kind":"row","n":32000,"rounds":10,"round_trips":320000,"wall_ns":440592583,"wall_ms":440.592583,"usec_per_roundtrip":1.3768518218749999,"reds_per_roundtrip":3.4120625,"ops_per_sec":726294.568603757}
  ```
* **Audit Finding:** Linear scaling maintained up to 32,000 concurrent processes (1.38 µs/roundtrip, 726k ops/sec).

---

### 2.8. Cosmos Point-Read Benchmark Preflight (`bench/bench_cosmos_cas.erl`)
* **Module / File:** `bench/bench_cosmos_cas.erl`
* **Objective:** Test TLS twin (port 9444) preflight skip contract.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && erl -pa _bench-escript/ebin -noshell -s bench_cosmos_cas main -s init stop
  ```
* **Exit Code:** `3` (Typed Skip)
* **Verbatim Output:**
  ```
  [BENCH-3-SKIP] substrate :9444 not LISTENING - lane never restarts it. 'just substrate-up' then rerun.
  ```
* **Audit Finding:** Preflight honors the typed exit-code contract: rc=3 when substrate is not active, never faking a pass.

---

### 2.9. Root Benchmark Harness (`scripts/bench.py`)
* **Module / File:** `scripts/bench.py`, `scripts/stress/_substrate.py`
* **Objective:** Spawn local substrate and measure PRD CTQs (Doctor, Boot, ARM PUT, Cosmos Doc, AMQP Header exchange).
* **Execution Command:**
  ```bash
  python3 /Users/sac/smalt/scripts/bench.py
  ```
* **Exit Code:** `1` (Failure)
* **Verbatim Output:**
  ```
  [BENCH] doctor (substrate stopped, as doctor requires)
    1.613s (target <= 3.0s) -> PASS
  [BENCH] substrate boot (spawn -> TCP accept on 9443), 5 runs
  [FAULT] substrate exited rc=1 before binding :9443
  ```
* **Substrate Log Inspection (`tmp/bench-substrate.log`):**
  ```
  Unchecked dependencies for environment dev:
  * stream_data (Hex package)
    the dependency is not available, run "mix deps.get"
  * toml (Hex package)
    the dependency is not available, run "mix deps.get"
  * json_ld (Hex package)
    the dependency is not available, run "mix deps.get"
  * jason (Hex package)
    the dependency is not available, run "mix deps.get"
  * spark (Hex package)
    the dependency is not available, run "mix deps.get"
  * finch (Hex package)
    the dependency is not available, run "mix deps.get"
  ...
  ** (Mix) Can't continue due to errors on dependencies
  ```
* **Audit Finding:** `scripts/bench.py` sets `MIX_ENV=dev`. In the local workspace, `deps/` does not exist or is unpopulated for `dev`. Consequently, `scripts/bench.py` fails during boot and is currently broken in this checkout.

---

### 2.10. Benchmark Framework Census Gate (`just bench-framework-gate` & `-court`)
* **Module / File:** `scripts/bench_framework_gate.py`, `justfile.d/47-bench-framework.just`
* **Objective:** Verify BENCH-14 zero-framework gate and anti-vacuity self-check.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt && just bench-framework-gate && just bench-framework-gate-court
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output:**
  ```
  == bench-framework gate census (/Users/sac/smalt)
     benchee allowlist : 1 file(s), frozen
     :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
     VERDICT: PASS
  == bench-framework gate census (/Users/sac/.cache/tmp/bench_framework_gate_selfcheck__2oiwnrm)
     benchee allowlist : 1 file(s), frozen
     :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
     VERDICT: FAIL (3 violation(s))
       - BENCHEE-REF mix.exs: benchee reference outside frozen allowlist (scripts/bench/benchee_runner.exs); receipt: docs/jira/v26.10.14/receipts/errc2-benchee.md
       - TIMER-TC scripts/bench/zz_shim_probe.exs:1: unannotated :timer.tc in scripts/bench without `# BENCH-CLASS: probe` and outside the frozen allowlist; receipt: docs/jira/v26.10.21/receipts/bench9-deletion-audit.md
       - TIMER-TC scripts/bench/zz_shim_probe.exs:2: unannotated :timer.tc in scripts/bench without `# BENCH-CLASS: probe` and outside the frozen allowlist; receipt: docs/jira/v26.10.21/receipts/bench9-deletion-audit.md
     self-check shim: injected benchee dep + unannotated :timer.tc -> REFUSED (non-vacuity proof)
  == bench-framework gate census (/Users/sac/smalt)
     benchee allowlist : 1 file(s), frozen
     :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
     VERDICT: PASS
     self-check clean: real tree -> PASS
  ```
* **Audit Finding:** Non-vacuity verified: Injected mutations into temporary trees trigger verified refusal, proving that the census gate is real and non-vacuous.

---

### 2.11. `posh` Go Membrane Benchmarks
* **Module / File:** `posh/internal/swissmap`, `posh/internal/telemetry/...`, `posh/internal/uniqueintern`
* **Objective:** Benchmark routing table lookup, lock-free telemetry serialization, and interned string pointer equality.
* **Execution Command:**
  ```bash
  cd /Users/sac/smalt/posh && go test ./internal/swissmap ./internal/telemetry/... ./internal/uniqueintern -run '^$' -bench . -benchmem
  ```
* **Exit Code:** `0` (Pass)
* **Verbatim Output:**
  ```
  goos: darwin
  goarch: arm64
  pkg: smalt.dev/posh/internal/swissmap
  cpu: Apple M3 Max
  BenchmarkRouteTableComparison/StandardMapRWMutexParallel-16         	14469093	       113.6 ns/op	       0 B/op	       0 allocs/op
  BenchmarkRouteTableComparison/SwissRouterWaitFreeParallel-16        	153001628	        11.13 ns/op	       0 B/op	       0 allocs/op
  PASS
  ok  	smalt.dev/posh/internal/swissmap	25.424s
  PASS
  ok  	smalt.dev/posh/internal/telemetry	24.855s
  goos: darwin
  goarch: arm64
  pkg: smalt.dev/posh/internal/telemetry/diffpprof
  cpu: Apple M3 Max
  BenchmarkCompareProfiles-16    	  201357	      9056 ns/op	    3170 B/op	      47 allocs/op
  PASS
  ok  	smalt.dev/posh/internal/telemetry/diffpprof	32.890s
  goos: darwin
  goarch: arm64
  pkg: smalt.dev/posh/internal/telemetry/fastmetrics
  cpu: Apple M3 Max
  BenchmarkFastSeries_Inc-16                   	297116882	         5.095 ns/op	       0 B/op	       0 allocs/op
  BenchmarkRequestVector_RecordPreWarmed-16    	13397373	        79.60 ns/op	      16 B/op	       1 allocs/op
  BenchmarkDenseRequestVector_Record-16        	100000000	        13.97 ns/op	       0 B/op	       0 allocs/op
  BenchmarkFastVector_AppendRender-16          	 1997841	       903.3 ns/op	       0 B/op	       0 allocs/op
  PASS
  ok  	smalt.dev/posh/internal/telemetry/fastmetrics	28.045s
  goos: darwin
  goarch: arm64
  pkg: smalt.dev/posh/internal/telemetry/otlp
  cpu: Apple M3 Max
  BenchmarkAppendTraceSpansProtobuf-16    	  136249	     12456 ns/op	       0 B/op	       0 allocs/op
  BenchmarkAppendTraceSpansJSON-16        	  125172	     13457 ns/op	       0 B/op	       0 allocs/op
  PASS
  ok  	smalt.dev/posh/internal/telemetry/otlp	21.394s
  PASS
  ok  	smalt.dev/posh/internal/telemetry/profiler	9.471s
  PASS
  ok  	smalt.dev/posh/internal/telemetry/socket	6.266s
  goos: darwin
  goarch: arm64
  pkg: smalt.dev/posh/internal/telemetry/tracing
  cpu: Apple M3 Max
  BenchmarkParseTraceparent-16       	11318467	       106.0 ns/op	       0 B/op	       0 allocs/op
  BenchmarkTraceContext_String-16    	19092153	        57.03 ns/op	      64 B/op	       1 allocs/op
  PASS
  ok  	smalt.dev/posh/internal/telemetry/tracing	8.021s
  goos: darwin
  goarch: arm64
  pkg: smalt.dev/posh/internal/uniqueintern
  cpu: Apple M3 Max
  BenchmarkStringEqualityCheck/StandardStringMemequal-16         	734508939	         1.716 ns/op	       0 B/op	       0 allocs/op
  BenchmarkStringEqualityCheck/InternedHandlePointerEquality-16  	1000000000	         0.4057 ns/op	       0 B/op	       0 allocs/op
  BenchmarkMemoryFootprint10kResources/StandardUninternedMemory-16         	     433	   2940056 ns/op	 2246672 B/op	   10001 allocs/op
  BenchmarkMemoryFootprint10kResources/InternedHandleMemory-16             	     309	   3907189 ns/op	 1763370 B/op	   10001 allocs/op
  BenchmarkConcurrentInterning-16                                          	 4424292	       264.5 ns/op	       0 B/op	       0 allocs/op
  PASS
  ok  	smalt.dev/posh/internal/uniqueintern	12.874s
  ```
* **Audit Finding:** SwissRouter wait-free router achieves 11.13 ns/op (over 10x faster than RWMutex map). Pointer equality over interned strings achieves 0.4057 ns/op (4.2x faster than standard memequal). Zero allocations achieved across telemetry renderers and protobuf serializations.

---

### 2.12. `popcorn_demo` Benchmarks (`popcorn-bench-*`)
* **Module / File:** `popcorn_demo/scripts/bench_legs.sh`, `bench_cook.sh`, `bench_scvd.sh`
* **Objective:** Benchmark host legs, browser cook, and SCVD memory scaling.
* **Execution Commands & Outputs:**
  ```bash
  cd /Users/sac/smalt && just popcorn-bench-legs
  # Output: BLOCKED: substrate down at http://127.0.0.1:9443/metadata/endpoints -> just substrate-up
  # Exit Code: 2

  cd /Users/sac/smalt && just popcorn-bench-cook
  # Output: BLOCKED: substrate down at http://127.0.0.1:9443/metadata/endpoints -> just substrate-up
  # Exit Code: 2

  cd /Users/sac/smalt && just popcorn-bench-scvd
  # Output:
  # machine: {"cpu": "Apple M3 Max", "cores": 16, "ram_gb": 48, "elixir": "1.20.3", "otp": "28", "darwin": "26.2"}
  # == baseline ==
  # Exit Code: 1
  ```
* **Root Cause for `popcorn-bench-scvd`:**
  Executing `cd /Users/sac/smalt/popcorn_demo && mix compile` yields:
  ```
  Unchecked dependencies for environment dev:
  * jason (Hex package)
    the dependency is not available, run "mix deps.get"
  * popcorn (Hex package)
    the dependency is not available, run "mix deps.get"
  ** (Mix) Can't continue due to errors on dependencies
  ```
* **Audit Finding:** `popcorn_demo` cannot execute its benchmarks because external hex dependencies (`jason`, `popcorn`) are not vendored, violating offline repeatability principles.

---

## 3. Detailed Audit of Unbenchmarked Surfaces

The following critical system surfaces have zero automated performance, throughput, or latency benchmarks in the repository:

### Surface 1: Blob Storage Data Plane (Port 8443)
* **Components:** `lib/smalt/data_plane/blob/`, `lib/smalt/data_plane/blob_routes.ex`
* **Unmeasured Operations:**
  - `PUT /<account>/<container>/<blob>` (Block blob upload, 1 KB to 100 MB).
  - `GET /<account>/<container>/<blob>` (Chunked/streaming range reads).
  - Append Blob operations (`AppendBlock`, concurrent appends, block count limits).
  - Page Blob random-write latencies (`PutPage`).
* **Gap Impact:** Blob storage throughput is critical for data-intensive client workloads, but no automated saturation or regression test exists.

### Surface 2: Key Vault REST 7.4 Data Plane (Port 8443 / 9444)
* **Components:** `lib/smalt/data_plane/key_vault/`, `posh/internal/dialect/azure/kv7`
* **Unmeasured Operations:**
  - Secret `SET` / `GET` / `DELETE` / `PURGE`.
  - Cryptographic operations: `encrypt`, `decrypt`, `sign`, `verify`, `wrapKey`, `unwrapKey` via BEAM `:crypto`.
  - Challenge auth handshake latency (tokenless 401 challenge roundtrip).
* **Gap Impact:** Key Vault is on the hot path of nearly all cloud client bootstraps; crypto latency has no automated regression tracking.

### Surface 3: Azure App Configuration CAS Engine
* **Components:** `lib/smalt/data_plane/app_config/`
* **Unmeasured Operations:**
  - Key-value write under high conditional-eTag contention (`If-Match` / `If-None-Match`).
  - Sentinel key watch / polling response latency.
* **Gap Impact:** Invariant gate `appconfig-etag-cas` tests correctness, but performance under contention is unmeasured.

### Surface 4: Confidential Ledger Service
* **Components:** `lib/smalt/confidential_ledger/service.ex`, `router.ex`
* **Unmeasured Operations:**
  - Transaction append rate (`POST /app/transactions`).
  - In-flight `PENDING` to `Committed` state transition delay.
  - Merkle root calculation & cryptographic receipt generation.
* **Gap Impact:** The ledger uses complex consensus simulation and SHA-256 Merkle trees; compute tax is unbenchmarked.

### Surface 5: Kinesis REST Face & SigV4 Verification
* **Components:** `lib/smalt/egress/kinesis_routes.ex`
* **Unmeasured Operations:**
  - `PutRecord` and `PutRecords` batch ingestion throughput.
  - AWS SigV4 recalculation and comparison overhead per inbound request.
* **Gap Impact:** SigV4 verification requires hashing the entire body payload; CPU tax under high payload sizes is unprofiled.

### Surface 6: Event Hubs Kafka Wire Protocol Engine
* **Components:** `lib/smalt/eventhubs/kafka.ex`, `lib/smalt/messaging/kafka/records.ex`
* **Unmeasured Operations:**
  - Kafka binary framing parser throughput (`Produce` and `Fetch` API versions 0–7).
  - Partition assignment & consumer group rebalance protocol latency.
* **Gap Impact:** While raw AMQP frame decoding is benchmarked (`bench_amqp_frame.erl`), Kafka binary record batch encoding/decoding has no standalone benchmark.

### Surface 7: FastMCP Tool Server (Port 9545)
* **Components:** `lib/smalt/mcp/`
* **Unmeasured Operations:**
  - JSON-RPC tool dispatch latency (`tools/call`, `tools/list`).
  - Server-Sent Events (SSE) concurrent streaming broadcast overhead.
* **Gap Impact:** MCP is the primary agentic control surface; dispatch delays directly degrade agent loop latency.

### Surface 8: Sovereign Console (`workspace/`)
* **Components:** `workspace/` Next.js 16 application
* **Unmeasured Operations:**
  - Next.js Server Action dispatch latency.
  - React Server Components (RSC) hydration budget.
  - Air-gapped local IndexedDB / WebLocks sync throughput.
* **Gap Impact:** E2E courts exist (`workspace/scripts/e2e-court.mjs`), but client-side rendering and memory budgets are unmeasured.

### Surface 9: Rust CLI `smaltctl` (`cli/`)
* **Components:** `cli/src/main.rs`, `cli/src/custom_handlers.rs`
* **Unmeasured Operations:**
  - Process startup time (`smaltctl --help`, `smaltctl status`).
  - BLAKE3 turnstile verification latency.
* **Gap Impact:** Zero cargo benchmarks (`[[bench]]`) exist in `cli/Cargo.toml`.

### Surface 10: Python CLI (`smalt-cli/`)
* **Components:** `smalt-cli/smalt_cli/`
* **Unmeasured Operations:**
  - Typer CLI command dispatch overhead.
  - Local endpoint cache lookup and session persistence latency.
* **Gap Impact:** `.benchmarks` directory is empty; no `pytest-benchmark` fixtures exist in `smalt-cli/tests/`.

---

## 4. Production Readiness & Architectural Gaps

### 4.1. Open Token Analysis
1. **`PENDING-BENCH-1` (`scripts/bench/erlang_bench.escript`):**
   - *Status:* OPEN since v26.10.21.
   - *Issue:* Contract AR-BENCH-05 mandated a unified escript runner capable of invoking any bench lane by name from CLI arguments and emitting standardized JSONL receipts. It was never implemented, leaving developers with ad-hoc `erl -pa ...` invocation commands.
2. **`PENDING-BENCH-2` (GL-9 Pure-Erlang Denominator Court):**
   - *Status:* OPEN since v26.10.21.
   - *Issue:* Elixir harness `scripts/bench/gl9_governance_tax.exs` established a 47.24 reds/step governance tax, but no corresponding pure-Erlang court was ever authored to isolate runtime overhead from Elixir wrapper overhead.
3. **`KD-GCP-05` (GCP Wire Parity Open Register):**
   - *Status:* OPEN in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.
   - *Issue:* All GCP storage and compute parity cells remain unverified despite tests passing in `test/gcp/`.

### 4.2. Core vs Dialect Separation (`posh` Go Membrane)
- Per `docs/jira/v26.10.31/00-charter.md`, the smalt BEAM core is intended to remain proprietary-free (governed strictly by `priv/ontologies/public-cloud-core.ttl`).
- The Azure/ARM face is being migrated into `posh` as Dialect #1.
- *Gap:* The cutover of port `:9443` requires cordoning the BEAM ARM router before `posh` binds. Currently, both layers compete for port definitions unless explicitly namespaced, and `mix.exs` still contains active ARM router code.

### 4.3. Offline Repeatability Violations
- In accordance with sovereign air-gapped doctrine, tests and benchmarks must never require external internet access at runtime.
- `popcorn_demo/` and `scripts/bench.py` fail immediately when executed in environments where `mix deps.get` has not been pre-run or when packages are not vendored into `deps/`.

---

## 5. Prioritized Remediation Roadmap

| Priority | Issue / Surface | File(s) | Remediation Plan |
|---|---|---|---|
| **P0 (Critical)** | `bin/court-bench` Vacuous Stubs | `bench/smalt_bench_court.erl`, `bin/court-bench` | Export `run_all/0` in `smalt_bench_court.erl` that executes the registered benchmark suite (`bench_amqp_frame`, `bench_powl_pipeline`, `bench_concurrency_ceiling`, etc.) instead of the 3 mock stubs. |
| **P0 (Critical)** | `scripts/bench.py` Boot Failure | `scripts/bench.py`, `mix.exs` | Ensure `scripts/bench.py` runs with pre-compiled artifacts or vendored dependencies, or uses `MIX_ENV=test` where compiled beams already exist. |
| **P1 (High)** | Brittle Wall-Clock Gate in `bench_json_streaming.erl` | `bench/bench_json_streaming.erl` | Replace the absolute `<= 100ms` gate with an anti-vacuity ratio fence or dynamic calibration band based on monotonic reductions and peak heap. |
| **P1 (High)** | Unvendored `popcorn_demo` Dependencies | `popcorn_demo/mix.exs` | Vendor required packages (`jason`, `popcorn`) into `popcorn_demo/deps` or link to root dependencies so `popcorn-bench-scvd` runs offline. |
| **P1 (High)** | Missing `scripts/bench/erlang_bench.escript` | `scripts/bench/` | Author the escript to close open token `PENDING-BENCH-1`. |
| **P2 (Medium)** | Data Plane Benchmarks | `scripts/bench/` | Author standardized bench lanes for Blob Storage (PUT/GET), Key Vault crypto operations, and App Config CAS contention. |
| **P2 (Medium)** | MCP Surface Benchmarking | `lib/smalt/mcp/` | Create a FastMCP concurrent load test measuring p50/p95/p99 JSON-RPC dispatch times on port `:9545`. |
| **P2 (Medium)** | CLI Performance Harnesses | `cli/`, `smalt-cli/` | Add Criterion benchmarks (`[[bench]]`) to `cli/Cargo.toml` and pytest-benchmark tests to `smalt-cli/tests/`. |
| **P3 (Low)** | GL-9 Pure-Erlang Court | `bench/` | Author pure-Erlang GL-9 governance tax court to close open token `PENDING-BENCH-2`. |

---
**Verification Stamp:** All findings verified on-disk with live tool execution receipts. No source or test files were modified.
